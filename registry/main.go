package main

import (
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
)

//go:embed index.html
var indexHTML []byte

// Config holds the server's runtime configuration, loaded from environment
// variables by loadConfig.
type Config struct {
	ListenAddr string
	DataDir    string
	PushToken  string
}

// loadConfig reads LISTEN_ADDR, DATA_DIR, and PUSH_TOKEN via getenv
// (os.Getenv in production, a stub in tests). LISTEN_ADDR defaults to
// ":8080" and DATA_DIR to "./data" when unset. PUSH_TOKEN has no default:
// loadConfig returns an error if it is empty, since an empty push token
// would mean push requests are accepted unauthenticated.
func loadConfig(getenv func(string) string) (Config, error) {
	cfg := Config{
		ListenAddr: getenv("LISTEN_ADDR"),
		DataDir:    getenv("DATA_DIR"),
		PushToken:  getenv("PUSH_TOKEN"),
	}
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":8080"
	}
	if cfg.DataDir == "" {
		cfg.DataDir = "./data"
	}
	if cfg.PushToken == "" {
		return Config{}, errors.New("PUSH_TOKEN must be set")
	}
	return cfg, nil
}

var bundlePath = regexp.MustCompile(`^/bundles/([^/]+)/([^/]+)$`)

// maxBundleBytes caps the size of a pushed bundle body. It is a package
// var (not a const) so tests can lower it temporarily to exercise the
// limit-exceeded path without allocating hundreds of megabytes.
var maxBundleBytes int64 = 512 * 1024 * 1024

// Server implements http.Handler for brain-registry's HTTP surface: the
// /bundles/{name}/{version} push/pull API, the JSON bundle listing at
// /api/bundles, and the HTML viewer at /.
type Server struct {
	storage   *Storage
	pushToken string
	mux       *http.ServeMux
}

// NewServer builds a Server with its routing table wired up. Use this
// instead of a bare &Server{...} literal so the mux is always initialized.
func NewServer(storage *Storage, pushToken string) *Server {
	s := &Server{storage: storage, pushToken: pushToken}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("GET /api/bundles", s.handleListBundles)
	mux.HandleFunc("/bundles/", s.serveBundles)
	s.mux = mux
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

// serveBundles is the /bundles/{name}/{version} push/pull dispatch. Its
// behavior is unchanged from before this task -- only how it's reached
// (via the mux instead of being the top-level ServeHTTP) changed.
func (s *Server) serveBundles(w http.ResponseWriter, r *http.Request) {
	m := bundlePath.FindStringSubmatch(r.URL.Path)
	if m == nil {
		http.NotFound(w, r)
		return
	}
	name, version := m[1], m[2]

	switch r.Method {
	case http.MethodPut:
		s.handlePush(w, r, name, version)
	case http.MethodGet:
		s.handlePull(w, name, version)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// handleIndex serves the embedded static HTML viewer page.
func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(indexHTML)
}

// handleListBundles serves the JSON bundle/version listing consumed by the
// HTML viewer's <script>. Unauthenticated, matching the pull policy.
func (s *Server) handleListBundles(w http.ResponseWriter, r *http.Request) {
	bundles, err := s.storage.List()
	if err != nil {
		log.Printf("storage error: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(bundles); err != nil {
		log.Printf("encode error: %v", err)
	}
}

func (s *Server) handlePush(w http.ResponseWriter, r *http.Request, name, version string) {
	if r.Header.Get("Authorization") != "Bearer "+s.pushToken {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBundleBytes)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "failed to read body", http.StatusInternalServerError)
		return
	}
	if err := s.storage.Put(name, version, data); err != nil {
		writeStorageError(w, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

func (s *Server) handlePull(w http.ResponseWriter, name, version string) {
	data, err := s.storage.Get(name, version)
	if err != nil {
		writeStorageError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/x-tar")
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

// writeStorageError maps a Storage error to the appropriate HTTP status:
// ErrNotFound -> 404, *validationError -> 400, anything else -> 500.
func writeStorageError(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	var ve *validationError
	if errors.As(err, &ve) {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	log.Printf("storage error: %v", err)
	http.Error(w, "internal error", http.StatusInternalServerError)
}

func main() {
	cfg, err := loadConfig(os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(cfg.DataDir, 0o755); err != nil {
		log.Fatal(err)
	}
	srv := NewServer(NewStorage(cfg.DataDir), cfg.PushToken)
	log.Printf("brain-registry listening on %s (data dir %s)", cfg.ListenAddr, cfg.DataDir)
	log.Fatal(http.ListenAndServe(cfg.ListenAddr, srv))
}
