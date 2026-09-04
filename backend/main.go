// Command excalidraw-store is the small storage service this image ships instead
// of the usual one.
//
// Excalidraw's own frontend needs three things kept somewhere:
//
//	scenes  a drawing published as a shareable link
//	rooms   the encrypted scene of a live session, so a latecomer sees the
//	        current state and the session survives everyone closing the tab
//	files   images pasted into a drawing
//
// The room server only relays messages between connected browsers; it stores
// nothing, which is why a separate store exists at all. Upstream that store is
// Google Firestore, and the usual self-hosted replacement is a Node service
// whose published image has not moved since February 2022.
//
// This is that service, in one static binary against SQLite: the same routes,
// no Node, no dependency that stopped being maintained while nobody looked.
//
// Everything stored here is already ENCRYPTED by the browser. The key lives in
// the URL fragment after the "#", which browsers never send to a server, so this
// service holds ciphertext it cannot read. That is a property of Excalidraw's
// design, not something this code has to arrange, but it is the reason a plain
// blob store is enough and no access control is needed for the blobs themselves.
package main

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// maxBlob caps a single stored object. Excalidraw scenes are tens of kilobytes;
// a pasted image is the large case. Generous enough not to be hit in normal use,
// small enough that the store cannot be turned into free file hosting.
const maxBlob = 50 << 20 // 50 MiB

type store struct{ db *sql.DB }

func main() {
	addr := envOr("STORE_ADDR", "127.0.0.1:8081")
	path := envOr("STORE_DB", "/config/store.sqlite")

	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil {
		log.Fatalf("store: open %s: %v", path, err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS blobs (
		kind    TEXT NOT NULL,
		id      TEXT NOT NULL,
		body    BLOB NOT NULL,
		created INTEGER NOT NULL,
		PRIMARY KEY (kind, id)
	)`); err != nil {
		log.Fatalf("store: schema: %v", err)
	}

	s := &store{db: db}
	mux := http.NewServeMux()
	// The frontend posts a new scene and gets an id back; everything else is
	// addressed by an id the caller already knows.
	mux.HandleFunc("POST /api/v2/scenes", s.createScene)
	mux.HandleFunc("GET /api/v2/scenes/{id}", s.get("scenes"))
	mux.HandleFunc("GET /api/v2/rooms/{id}", s.get("rooms"))
	mux.HandleFunc("PUT /api/v2/rooms/{id}", s.put("rooms"))
	mux.HandleFunc("GET /api/v2/files/{id}", s.get("files"))
	mux.HandleFunc("PUT /api/v2/files/{id}", s.put("files"))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		if err := db.Ping(); err != nil {
			http.Error(w, "database unavailable", http.StatusServiceUnavailable)
			return
		}
		_, _ = io.WriteString(w, "ok")
	})

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("store: listening on %s, database %s", addr, path)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("store: %v", err)
	}
}

// createScene stores a new drawing and answers with its id, the shape the
// frontend expects from the shared-link endpoint.
func (s *store) createScene(w http.ResponseWriter, r *http.Request) {
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	id, err := newID()
	if err != nil {
		log.Printf("store: id: %v", err)
		http.Error(w, "could not allocate an id", http.StatusInternalServerError)
		return
	}
	if err := s.save("scenes", id, body); err != nil {
		log.Printf("store: save scene: %v", err)
		http.Error(w, "could not store the drawing", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	fmt.Fprintf(w, `{"id":%q,"data":"OK"}`, id)
}

func (s *store) get(kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		var body []byte
		err := s.db.QueryRow(`SELECT body FROM blobs WHERE kind = ? AND id = ?`, kind, id).Scan(&body)
		if errors.Is(err, sql.ErrNoRows) {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		if err != nil {
			log.Printf("store: read %s/%s: %v", kind, id, err)
			http.Error(w, "could not read it back", http.StatusInternalServerError)
			return
		}
		// Opaque ciphertext, so no content type is claimed beyond "bytes".
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(body)
	}
}

// put is the write half for rooms and files, both of which are addressed by an
// id the browser already chose. A repeated write replaces the old value: a live
// session saves its scene again and again under the same room id, and keeping
// every version would grow without bound for no reader.
func (s *store) put(kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if strings.TrimSpace(id) == "" {
			http.Error(w, "missing id", http.StatusBadRequest)
			return
		}
		body, ok := readBody(w, r)
		if !ok {
			return
		}
		if err := s.save(kind, id, body); err != nil {
			log.Printf("store: save %s/%s: %v", kind, id, err)
			http.Error(w, "could not store it", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}

func (s *store) save(kind, id string, body []byte) error {
	_, err := s.db.Exec(
		`INSERT INTO blobs (kind, id, body, created) VALUES (?, ?, ?, ?)
		 ON CONFLICT(kind, id) DO UPDATE SET body = excluded.body, created = excluded.created`,
		kind, id, body, time.Now().Unix(),
	)
	return err
}

// readBody enforces the size cap and reports the refusal itself, so every
// handler treats an oversized upload the same way.
func readBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBlob+1))
	if err != nil {
		http.Error(w, "could not read the request", http.StatusBadRequest)
		return nil, false
	}
	if len(body) > maxBlob {
		http.Error(w, "too large", http.StatusRequestEntityTooLarge)
		return nil, false
	}
	if len(body) == 0 {
		http.Error(w, "empty body", http.StatusBadRequest)
		return nil, false
	}
	return body, true
}

// newID mints the 16-digit numeric id the frontend's share links are built
// around. Sixteen digits from crypto/rand, not a counter: an id that can be
// guessed is a drawing that can be found by someone who was never given the
// link, and the link is the only thing standing in front of it.
func newID() (string, error) {
	const digits = 16
	var b strings.Builder
	b.Grow(digits)
	for i := 0; i < digits; i++ {
		n, err := rand.Int(rand.Reader, big.NewInt(10))
		if err != nil {
			return "", err
		}
		b.WriteByte(byte('0' + n.Int64()))
	}
	return b.String(), nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
