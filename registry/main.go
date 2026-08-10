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

// Config は loadConfig が環境変数から読み込むサーバー実行時設定を保持する。
type Config struct {
	ListenAddr string
	DataDir    string
	PushToken  string
}

// loadConfig は getenv 経由で LISTEN_ADDR、DATA_DIR、PUSH_TOKEN を読む
//（本番では os.Getenv、テストではスタブ）。未設定時の LISTEN_ADDR は
// ":8080"、DATA_DIR は "./data"。PUSH_TOKEN に既定値はなく、空だと push
// リクエストが認証なしで受け付けられるためエラーを返す。
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

// maxBundleBytes は push されるバンドル本文の上限。数百 MB を確保せずに
// 上限超過経路をテストできるよう、const ではなくテスト中に一時変更できる
// package 変数にしている。
var maxBundleBytes int64 = 512 * 1024 * 1024

// Server は brain-registry の HTTP インターフェースを実装する。
// /bundles/{name}/{version} の push/pull API、/api/bundles の JSON 一覧、
// / の HTML ビューアーを提供する。
type Server struct {
	storage   *Storage
	pushToken string
	mux       *http.ServeMux
}

// NewServer はルーティングを設定済みの Server を構築する。mux が必ず初期化される
// よう、&Server{...} のリテラルを直接使わずこちらを使う。
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

// serveBundles は /bundles/{name}/{version} の push/pull を振り分ける。
// 以前からの挙動は変えず、トップレベルの ServeHTTP から mux 経由で呼ぶ形に変更
// している。
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

// handleIndex は埋め込み済みの静的 HTML ビューアーページを返す。
func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(indexHTML)
}

// handleListBundles は HTML ビューアーの <script> が使うバンドル／バージョン
// 一覧 JSON を返す。pull と同じ方針で認証は要求しない。
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

// writeStorageError は Storage のエラーを HTTP ステータスへ変換する。
// ErrNotFound は 404、*validationError は 400、それ以外は 500 にする。
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
