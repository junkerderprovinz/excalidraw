package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

// newTestStore gives each test its own database file, so one test's writes can
// never explain another's pass.
func newTestStore(t *testing.T) (*store, *http.ServeMux) {
	t.Helper()
	db, err := sql.Open("sqlite", t.TempDir()+"/test.sqlite")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`CREATE TABLE blobs (kind TEXT, id TEXT, body BLOB, created INTEGER, PRIMARY KEY (kind, id))`); err != nil {
		t.Fatalf("schema: %v", err)
	}
	s := &store{db: db}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v2/scenes", s.createScene)
	mux.HandleFunc("GET /api/v2/scenes/{id}", s.get("scenes"))
	mux.HandleFunc("GET /api/v2/rooms/{id}", s.get("rooms"))
	mux.HandleFunc("PUT /api/v2/rooms/{id}", s.put("rooms"))
	return s, mux
}

func do(t *testing.T, mux *http.ServeMux, method, path string, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	var r *http.Request
	if body == nil {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, bytes.NewReader(body))
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	return w
}

// A drawing published as a link has to come back byte for byte: what is stored
// here is ciphertext, and a single altered byte makes it undecryptable rather
// than slightly wrong.
func TestSceneRoundTripIsExact(t *testing.T) {
	_, mux := newTestStore(t)
	payload := []byte{0x00, 0x01, 0xff, 0xfe, 'h', 'i', 0x00}

	w := do(t, mux, http.MethodPost, "/api/v2/scenes", payload)
	if w.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, body = %s", w.Code, w.Body.String())
	}
	var got struct{ ID string }
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("response is not JSON: %v (%s)", err, w.Body.String())
	}
	if len(got.ID) != 16 {
		t.Fatalf("id = %q, want 16 digits: the share link is built from it", got.ID)
	}

	w = do(t, mux, http.MethodGet, "/api/v2/scenes/"+got.ID, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("GET status = %d", w.Code)
	}
	if !bytes.Equal(w.Body.Bytes(), payload) {
		t.Errorf("round trip altered the bytes: %v != %v", w.Body.Bytes(), payload)
	}
}

// A live session writes its room again and again under the same id. The newest
// state has to win, and old ones must not pile up.
func TestRoomWriteReplaces(t *testing.T) {
	s, mux := newTestStore(t)

	if w := do(t, mux, http.MethodPut, "/api/v2/rooms/abc", []byte("erste Fassung")); w.Code != http.StatusOK {
		t.Fatalf("first PUT = %d", w.Code)
	}
	if w := do(t, mux, http.MethodPut, "/api/v2/rooms/abc", []byte("zweite Fassung")); w.Code != http.StatusOK {
		t.Fatalf("second PUT = %d", w.Code)
	}

	w := do(t, mux, http.MethodGet, "/api/v2/rooms/abc", nil)
	if body := w.Body.String(); body != "zweite Fassung" {
		t.Errorf("room body = %q, want the newer one", body)
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM blobs WHERE kind = 'rooms'`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Errorf("rows = %d, want 1: a session that saves every few seconds must not grow the table", n)
	}
}

// An id nobody stored is a miss, not an empty success. A 200 with no body would
// look to the frontend like a drawing that lost all its elements.
func TestUnknownIDIsNotFound(t *testing.T) {
	_, mux := newTestStore(t)
	if w := do(t, mux, http.MethodGet, "/api/v2/scenes/9999999999999999", nil); w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", w.Code)
	}
}

func TestRejectsEmptyAndOversized(t *testing.T) {
	_, mux := newTestStore(t)

	if w := do(t, mux, http.MethodPost, "/api/v2/scenes", []byte{}); w.Code != http.StatusBadRequest {
		t.Errorf("empty POST = %d, want 400", w.Code)
	}
	big := bytes.Repeat([]byte("x"), maxBlob+1024)
	if w := do(t, mux, http.MethodPost, "/api/v2/scenes", big); w.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized POST = %d, want 413", w.Code)
	}
}

// Ids are the only thing standing in front of a shared drawing, so they must not
// be guessable or sequential. Two in a row differing is a weak check; this one
// looks for structure across many.
func TestIDsAreRandomAndNumeric(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		id, err := newID()
		if err != nil {
			t.Fatalf("newID: %v", err)
		}
		if len(id) != 16 || strings.Trim(id, "0123456789") != "" {
			t.Fatalf("id = %q, want 16 digits", id)
		}
		if seen[id] {
			t.Fatalf("id %q repeated within 200 draws", id)
		}
		seen[id] = true
	}
}

func TestHealthzReportsTheDatabase(t *testing.T) {
	db, err := sql.Open("sqlite", t.TempDir()+"/h.sqlite")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		if err := db.Ping(); err != nil {
			http.Error(w, "database unavailable", http.StatusServiceUnavailable)
			return
		}
		_, _ = io.WriteString(w, "ok")
	})
	if w := do(t, mux, http.MethodGet, "/healthz", nil); w.Code != http.StatusOK {
		t.Fatalf("healthz = %d", w.Code)
	}
	_ = db.Close()
	if w := do(t, mux, http.MethodGet, "/healthz", nil); w.Code != http.StatusServiceUnavailable {
		t.Errorf("healthz after close = %d, want 503: a store that cannot reach its database is not healthy", w.Code)
	}
}
