package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestServer(t *testing.T) *Server {
	t.Helper()
	dir := t.TempDir()
	return NewServer(NewStorage(dir), "secret")
}

func TestPushWithoutTokenReturns401(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPut, "/bundles/webcam/v1", strings.NewReader("data"))
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("got status %d, want 401", w.Code)
	}
}

func TestPushWithWrongTokenReturns401(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPut, "/bundles/webcam/v1", strings.NewReader("data"))
	req.Header.Set("Authorization", "Bearer wrong")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("got status %d, want 401", w.Code)
	}
}

func TestPushThenGetRoundTrip(t *testing.T) {
	s := newTestServer(t)

	req := httptest.NewRequest(http.MethodPut, "/bundles/webcam/v1", strings.NewReader("tarbytes"))
	req.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("push: got status %d, want 201, body=%s", w.Code, w.Body.String())
	}

	req2 := httptest.NewRequest(http.MethodGet, "/bundles/webcam/v1", nil)
	w2 := httptest.NewRecorder()
	s.ServeHTTP(w2, req2)
	if w2.Code != http.StatusOK {
		t.Fatalf("get: got status %d, want 200", w2.Code)
	}
	if w2.Body.String() != "tarbytes" {
		t.Fatalf("get: got body %q, want %q", w2.Body.String(), "tarbytes")
	}
	if ct := w2.Header().Get("Content-Type"); ct != "application/x-tar" {
		t.Fatalf("got Content-Type %q, want application/x-tar", ct)
	}
}

func TestGetLatestResolvesToMostRecentPush(t *testing.T) {
	s := newTestServer(t)
	push := func(version, body string) {
		t.Helper()
		req := httptest.NewRequest(http.MethodPut, "/bundles/webcam/"+version, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		s.ServeHTTP(w, req)
		if w.Code != http.StatusCreated {
			t.Fatalf("push %s: got status %d, want 201", version, w.Code)
		}
	}
	push("v1", "one")
	push("v2", "two")

	req := httptest.NewRequest(http.MethodGet, "/bundles/webcam/latest", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got status %d, want 200", w.Code)
	}
	if w.Body.String() != "two" {
		t.Fatalf("got body %q, want %q", w.Body.String(), "two")
	}
}

func TestGetUnknownNameReturns404(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/bundles/nope/latest", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Fatalf("got status %d, want 404", w.Code)
	}
}

func TestPushInvalidNameReturns400(t *testing.T) {
	s := newTestServer(t)
	// %20 はスペースにデコードされ、セグメントの文字種検査で拒否される。
	// %2F は "/" にデコードされて 3 つ目のパスセグメントに分割され、
	// 検証まで到達しないため、同一セグメント内の不正文字を使う。
	req := httptest.NewRequest(http.MethodPut, "/bundles/web%20cam/v1", strings.NewReader("data"))
	req.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want 400, body=%s", w.Code, w.Body.String())
	}
}

func TestPushLiteralLatestVersionReturns400(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPut, "/bundles/webcam/latest", strings.NewReader("data"))
	req.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want 400, body=%s", w.Code, w.Body.String())
	}
}

func TestLoadConfigDefaults(t *testing.T) {
	env := map[string]string{"PUSH_TOKEN": "secret"}
	cfg, err := loadConfig(func(k string) string { return env[k] })
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.ListenAddr != ":8080" {
		t.Errorf("got ListenAddr %q, want :8080", cfg.ListenAddr)
	}
	if cfg.DataDir != "./data" {
		t.Errorf("got DataDir %q, want ./data", cfg.DataDir)
	}
	if cfg.PushToken != "secret" {
		t.Errorf("got PushToken %q, want secret", cfg.PushToken)
	}
}

func TestLoadConfigOverrides(t *testing.T) {
	env := map[string]string{
		"PUSH_TOKEN":  "secret",
		"LISTEN_ADDR": ":9090",
		"DATA_DIR":    "/var/lib/brain-registry",
	}
	cfg, err := loadConfig(func(k string) string { return env[k] })
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.ListenAddr != ":9090" {
		t.Errorf("got ListenAddr %q, want :9090", cfg.ListenAddr)
	}
	if cfg.DataDir != "/var/lib/brain-registry" {
		t.Errorf("got DataDir %q, want /var/lib/brain-registry", cfg.DataDir)
	}
}

func TestLoadConfigRequiresPushToken(t *testing.T) {
	env := map[string]string{}
	_, err := loadConfig(func(k string) string { return env[k] })
	if err == nil {
		t.Fatal("expected error when PUSH_TOKEN is unset, got nil")
	}
}

// TestGenericStorageErrorDoesNotLeakInternals は、バンドル名のディレクトリを作る場所に
// 通常ファイルを先に置き、os.MkdirAll が「ディレクトリではない」で失敗する状況を作る。
// クライアントへの応答は汎用メッセージにし、OS の生のエラー文やサーバーのデータ
// ディレクトリを返さないことを確認する。
func TestGenericStorageErrorDoesNotLeakInternals(t *testing.T) {
	dir := t.TempDir()
	// ストレージ層がバンドル "webcam" 用に作るディレクトリを、通常ファイルで
	// ふさいでおく。
	if err := os.WriteFile(filepath.Join(dir, "webcam"), []byte("x"), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	s := NewServer(NewStorage(dir), "secret")

	req := httptest.NewRequest(http.MethodPut, "/bundles/webcam/v1", strings.NewReader("data"))
	req.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("got status %d, want 500, body=%s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	if strings.Contains(body, "mkdir") {
		t.Errorf("response body leaks raw OS error text (contains %q): %s", "mkdir", body)
	}
	if strings.Contains(body, dir) {
		t.Errorf("response body leaks the server's data directory path: %s", body)
	}
}

// TestPushBodyOverLimitReturns413 は、設定した maxBundleBytes を超える
// リクエスト本文を 413 で拒否することを確認する。数百 MB を確保せずに済む
// よう、テスト中だけ上限を小さくする。
func TestPushBodyOverLimitReturns413(t *testing.T) {
	orig := maxBundleBytes
	maxBundleBytes = 16
	defer func() { maxBundleBytes = orig }()

	s := newTestServer(t)
	body := strings.Repeat("x", int(maxBundleBytes)+1)
	req := httptest.NewRequest(http.MethodPut, "/bundles/webcam/v1", strings.NewReader(body))
	req.ContentLength = int64(len(body))
	req.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("got status %d, want 413, body=%s", w.Code, w.Body.String())
	}
}

// TestPushBodyAtLimitSucceeds は、上限ちょうどの本文は許可し、「上限より
// 大きければ拒否」という条件が 1 バイトずれていないことを確認する。
func TestPushBodyAtLimitSucceeds(t *testing.T) {
	orig := maxBundleBytes
	maxBundleBytes = 16
	defer func() { maxBundleBytes = orig }()

	s := newTestServer(t)
	body := strings.Repeat("x", int(maxBundleBytes))
	req := httptest.NewRequest(http.MethodPut, "/bundles/webcam/v1", strings.NewReader(body))
	req.ContentLength = int64(len(body))
	req.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("got status %d, want 201, body=%s", w.Code, w.Body.String())
	}
}

func TestListBundlesEmpty(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/bundles", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got status %d, want 200", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("got Content-Type %q, want application/json", ct)
	}
	if strings.TrimSpace(w.Body.String()) != "{}" {
		t.Fatalf("got body %q, want {}", w.Body.String())
	}
}

func TestListBundlesReflectsPushedVersions(t *testing.T) {
	s := newTestServer(t)
	push := func(version, body string) {
		t.Helper()
		req := httptest.NewRequest(http.MethodPut, "/bundles/webcam/"+version, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		s.ServeHTTP(w, req)
		if w.Code != http.StatusCreated {
			t.Fatalf("push %s: got status %d, want 201", version, w.Code)
		}
	}
	push("v1", "one")
	push("v2", "two")

	req := httptest.NewRequest(http.MethodGet, "/api/bundles", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got status %d, want 200", w.Code)
	}
	var got map[string]BundleInfo
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal: %v, body=%s", err, w.Body.String())
	}
	webcam, ok := got["webcam"]
	if !ok {
		t.Fatalf("response missing webcam bundle: %s", w.Body.String())
	}
	if len(webcam.Versions) != 2 || webcam.Versions[0] != "v1" || webcam.Versions[1] != "v2" {
		t.Fatalf("got versions %v, want [v1 v2]", webcam.Versions)
	}
	if webcam.Latest != "v2" {
		t.Fatalf("got latest %q, want v2", webcam.Latest)
	}
}

func TestIndexPageReturnsHTML(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got status %d, want 200", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "text/html; charset=utf-8" {
		t.Fatalf("got Content-Type %q, want text/html; charset=utf-8", ct)
	}
	if !strings.Contains(w.Body.String(), "<html") {
		t.Fatalf("body does not look like HTML: %s", w.Body.String())
	}
}

func TestUnknownPathReturns404NotIndex(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/nonexistent", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Fatalf("got status %d, want 404 (an unmatched path must not silently fall through to the index page)", w.Code)
	}
}
