// Replaces excalidraw-app/components/ExportToExcalidrawPlus.tsx.
//
// Derived from Excalidraw (MIT), whose file this replaces:
// https://github.com/excalidraw/excalidraw
//
// Upstream this is the "Export to Excalidraw+" card: it encrypts the drawing,
// uploads it to Firebase Storage and hands back a link into the commercial
// hosted product. This image keeps drawings on its own server, so the upload is
// gone.
//
// Both exports keep their signatures because App.tsx imports them. The card says
// where drawings stay instead of silently doing nothing. It uses plain markup and
// no imports from the Excalidraw packages, so a moved component cannot break it.
//
// Everything else about exporting is untouched: saving to a file, copying to
// the clipboard, PNG and SVG export, and the shareable link, which stays in
// this container's own store.

import type {
  AppState,
  BinaryFiles,
  UIAppState,
} from "@excalidraw/excalidraw/types";
import type { NonDeletedExcalidrawElement } from "@excalidraw/element/types";

/** Kept so App.tsx's import resolves. Anyone calling it gets a clear refusal
 *  rather than a silent no-op. */
export const exportToExcalidrawPlus = async (
  elements: readonly NonDeletedExcalidrawElement[],
  appState: Partial<AppState>,
  files: BinaryFiles,
  name: string,
) => {
  void elements;
  void appState;
  void files;
  void name;
  throw new Error(
    "This build does not upload drawings anywhere. Save to a file, or share a link, which stays on this server.",
  );
};

export const ExportToExcalidrawPlus: React.FC<{
  elements: readonly NonDeletedExcalidrawElement[];
  appState: UIAppState;
  files: BinaryFiles;
  name: string;
  onError: (error: Error) => void;
  onSuccess: () => void;
}> = ({ elements, appState, files, name, onError, onSuccess }) => {
  void elements;
  void appState;
  void files;
  void name;
  void onError;
  void onSuccess;

  return (
    <div className="Card" style={{ lineHeight: 1.5 }}>
      <h2 style={{ marginTop: 0 }}>Stays on this server</h2>
      <div>
        This whiteboard sends nothing to anyone else. Use <b>Save to file</b> or{" "}
        <b>Export image</b> to take a drawing with you, or share a link: it is
        stored here and can only be read with the key that sits in the link
        itself.
      </div>
    </div>
  );
};
