// Replaces excalidraw-app/data/firebase.ts.
//
// Derived from Excalidraw (MIT), whose file this replaces. The upstream project
// is at https://github.com/excalidraw/excalidraw; only the destination of the
// bytes differs here, and the header above says exactly how.
//
// Upstream keeps three things in Google Firestore and Firebase Storage: the
// encrypted scene of a live session, so a latecomer sees the current state and
// the session survives everyone closing their tab, and the images pasted into a
// drawing. The room server only relays messages between connected browsers and
// stores nothing, which is why that store exists at all.
//
// This file keeps the same exports and the same encryption, and puts the bytes
// in the container's own store:
//
//   PUT/GET  /api/v2/rooms/<roomId>
//   PUT/GET  /api/v2/files/<fileId>
//
// Relative paths on purpose: the browser resolves them against whatever address
// the page was opened on, so one image works on a LAN address, behind a reverse
// proxy and under a subdomain without anything to configure.
//
// Deliberately unchanged from upstream: every encrypt and decrypt call, the
// reconcile step, the scene-version cache keyed by socket, the double cast
// through OrderedExcalidrawElement, and the re-read after writing (the in-memory
// reconciled elements can have moved on by then). The store only ever sees
// ciphertext — the key lives in the URL fragment, which browsers do not send.
//
// ONE difference in substance, and it is worth knowing: upstream wraps
// read-reconcile-write in a Firestore transaction. This store has no
// transactions, so two clients saving in the same instant can have one write
// land on a slightly older read. The reconcile is a merge rather than an
// overwrite and every client keeps saving as it draws, so the next save folds
// the two together; what a collision costs is one round of latency, not
// somebody's rectangle.

import { reconcileElements } from "@excalidraw/excalidraw";
import { MIME_TYPES, toBrandedType } from "@excalidraw/common";
import { decompressData } from "@excalidraw/excalidraw/data/encode";
import {
  encryptData,
  decryptData,
} from "@excalidraw/excalidraw/data/encryption";
import { restoreElements } from "@excalidraw/excalidraw/data/restore";
import { getSceneVersion } from "@excalidraw/element";

import type { RemoteExcalidrawElement } from "@excalidraw/excalidraw/data/reconcile";
import type {
  ExcalidrawElement,
  FileId,
  OrderedExcalidrawElement,
} from "@excalidraw/element/types";
import type {
  AppState,
  BinaryFileData,
  BinaryFileMetadata,
  DataURL,
} from "@excalidraw/excalidraw/types";

import { FILE_CACHE_MAX_AGE_SEC } from "../app_constants";

import { getSyncableElements } from ".";

import type { SyncableExcalidrawElement } from ".";
import type Portal from "../collab/Portal";
import type { Socket } from "socket.io-client";

const ROOMS = "/api/v2/rooms/";
const FILES = "/api/v2/files/";

// A stored room is one blob: version, then the initialisation vector, then the
// ciphertext. Upstream keeps the three as separate Firestore fields; packing
// them together keeps the store a plain key/value with nothing to understand.
const VERSION_BYTES = 4;
const IV_BYTES = 12;

class StoreError extends Error {}

const put = async (url: string, body: ArrayBuffer | Blob) => {
  const res = await fetch(url, { method: "PUT", body });
  if (!res.ok) {
    throw new StoreError(`store refused ${url}: ${res.status}`);
  }
};

const getBytes = async (url: string): Promise<Uint8Array | null> => {
  const res = await fetch(url);
  if (res.status === 404) {
    return null; // Nothing stored yet is a normal state, not a failure.
  }
  if (!res.ok) {
    throw new StoreError(`store failed ${url}: ${res.status}`);
  }
  return new Uint8Array(await res.arrayBuffer());
};

// Upstream hands out a Firebase Storage handle here. Nothing in this build needs
// one, and the export stays so every caller keeps compiling.
export const loadFirebaseStorage = async () => null;

class SceneVersionCache {
  private static cache = new WeakMap<Socket, number>();
  static get = (socket: Socket) => SceneVersionCache.cache.get(socket);
  static set = (
    socket: Socket,
    elements: readonly SyncableExcalidrawElement[],
  ) => {
    SceneVersionCache.cache.set(socket, getSceneVersion(elements));
  };
}

export const isSavedToFirebase = (
  portal: Portal,
  elements: readonly ExcalidrawElement[],
): boolean => {
  if (portal.socket && portal.roomId && portal.roomKey) {
    return SceneVersionCache.get(portal.socket) === getSceneVersion(elements);
  }
  // No room means nothing to sync, which counts as saved: refusing to unload the
  // page here would help nobody.
  return true;
};

export const saveFilesToFirebase = async ({
  prefix,
  files,
}: {
  prefix: string;
  files: { id: FileId; buffer: Uint8Array }[];
}) => {
  const erroredFiles: FileId[] = [];
  const savedFiles: FileId[] = [];

  await Promise.all(
    files.map(async ({ id, buffer }) => {
      try {
        // `prefix` is upstream's storage path. Here the id alone identifies the
        // file, and cache lifetime is nginx's business, not the uploader's.
        void prefix;
        void FILE_CACHE_MAX_AGE_SEC;
        await put(`${FILES}${id}`, buffer.buffer as ArrayBuffer);
        savedFiles.push(id);
      } catch (error: any) {
        console.error(`could not store file ${id}`, error);
        erroredFiles.push(id);
      }
    }),
  );

  return { savedFiles, erroredFiles };
};

const encryptScene = async (
  key: string,
  elements: readonly SyncableExcalidrawElement[],
): Promise<Uint8Array> => {
  const json = JSON.stringify(elements);
  const encoded = new TextEncoder().encode(json);
  const { encryptedBuffer, iv } = await encryptData(key, encoded);

  const out = new Uint8Array(
    VERSION_BYTES + IV_BYTES + encryptedBuffer.byteLength,
  );
  new DataView(out.buffer).setUint32(0, getSceneVersion(elements));
  out.set(iv, VERSION_BYTES);
  out.set(new Uint8Array(encryptedBuffer), VERSION_BYTES + IV_BYTES);
  return out;
};

const decryptScene = async (
  key: string,
  blob: Uint8Array,
): Promise<readonly ExcalidrawElement[]> => {
  const iv = blob.slice(VERSION_BYTES, VERSION_BYTES + IV_BYTES);
  const ciphertext = blob.slice(VERSION_BYTES + IV_BYTES);
  const decrypted = await decryptData(
    iv as Uint8Array<ArrayBuffer>,
    ciphertext as Uint8Array<ArrayBuffer>,
    key,
  );
  return JSON.parse(new TextDecoder("utf-8").decode(new Uint8Array(decrypted)));
};

// No explicit return type on purpose: getSyncableElements returns a mutable
// array, and declaring it readonly here is what made the cast below and
// toBrandedType fail. Let the inferred type carry the truth.
const loadRoom = async (roomId: string, roomKey: string) => {
  const blob = await getBytes(`${ROOMS}${roomId}`);
  if (!blob || blob.byteLength <= VERSION_BYTES + IV_BYTES) {
    return null;
  }
  return getSyncableElements(
    restoreElements(await decryptScene(roomKey, blob), null),
  );
};

export const saveToFirebase = async (
  portal: Portal,
  elements: readonly SyncableExcalidrawElement[],
  appState: AppState,
) => {
  const { roomId, roomKey, socket } = portal;
  if (!roomId || !roomKey || !socket || isSavedToFirebase(portal, elements)) {
    return null;
  }

  // Read, reconcile, write. Someone else may have saved since this client last
  // read, and overwriting would drop work that is already on their screen.
  const prevStoredElements = await loadRoom(roomId, roomKey);
  const reconciledElements = prevStoredElements
    ? getSyncableElements(
        reconcileElements(
          elements,
          prevStoredElements as OrderedExcalidrawElement[] as RemoteExcalidrawElement[],
          appState,
        ),
      )
    : elements;

  const scene = await encryptScene(roomKey, reconciledElements);
  await put(`${ROOMS}${roomId}`, scene.buffer as ArrayBuffer);

  // Read back what was actually stored rather than trusting the local copy: the
  // in-memory reconciled elements can have mutated while the write was in
  // flight, which is the same reason upstream returns the stored document.
  //
  // No fallback to the local copy if that read comes up empty. A room that is
  // not there one moment after it was written means the store lost the write,
  // and quietly carrying on with the local elements would hide that until
  // somebody notices their session never persisted.
  const storedElements = await loadRoom(roomId, roomKey);
  if (!storedElements) {
    throw new StoreError(`room ${roomId} was not there right after writing it`);
  }

  SceneVersionCache.set(socket, storedElements);

  return toBrandedType<RemoteExcalidrawElement[]>(storedElements);
};

export const loadFromFirebase = async (
  roomId: string,
  roomKey: string,
  socket: Socket | null,
): Promise<readonly SyncableExcalidrawElement[] | null> => {
  const elements = await loadRoom(roomId, roomKey);
  if (!elements) {
    return null;
  }
  if (socket) {
    SceneVersionCache.set(socket, elements);
  }
  return elements;
};

export const loadFilesFromFirebase = async (
  prefix: string,
  decryptionKey: string,
  filesIds: readonly FileId[],
) => {
  void prefix;
  const loadedFiles: BinaryFileData[] = [];
  const erroredFiles = new Map<FileId, true>();

  await Promise.all(
    [...new Set(filesIds)].map(async (id) => {
      try {
        const bytes = await getBytes(`${FILES}${id}`);
        if (!bytes) {
          erroredFiles.set(id, true);
          return;
        }
        const { data, metadata } = await decompressData<BinaryFileMetadata>(
          bytes as Uint8Array<ArrayBuffer>,
          { decryptionKey },
        );
        const dataURL = new TextDecoder().decode(data) as DataURL;
        loadedFiles.push({
          mimeType: metadata.mimeType || MIME_TYPES.binary,
          id,
          dataURL,
          created: metadata?.created || Date.now(),
          lastRetrieved: metadata?.created || Date.now(),
        });
      } catch (error: any) {
        console.error(`could not load file ${id}`, error);
        erroredFiles.set(id, true);
      }
    }),
  );

  return { loadedFiles, erroredFiles };
};
