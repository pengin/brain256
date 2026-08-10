package main

import (
	"errors"
	"os"
	"strings"
	"testing"
)

func TestPutGetRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s := NewStorage(dir)
	if err := s.Put("webcam", "v1", []byte("hello")); err != nil {
		t.Fatalf("Put: %v", err)
	}
	data, err := s.Get("webcam", "v1")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(data) != "hello" {
		t.Fatalf("got %q, want %q", data, "hello")
	}
}

func TestLatestResolvesToMostRecentPush(t *testing.T) {
	dir := t.TempDir()
	s := NewStorage(dir)
	if err := s.Put("webcam", "v1", []byte("one")); err != nil {
		t.Fatalf("Put v1: %v", err)
	}
	if err := s.Put("webcam", "v2", []byte("two")); err != nil {
		t.Fatalf("Put v2: %v", err)
	}
	data, err := s.Get("webcam", "latest")
	if err != nil {
		t.Fatalf("Get latest: %v", err)
	}
	if string(data) != "two" {
		t.Fatalf("got %q, want %q", data, "two")
	}
}

func TestCorruptLatestPointerIsRejected(t *testing.T) {
	dir := t.TempDir()
	s := NewStorage(dir)
	if err := os.MkdirAll(dir+"/webcam", 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(dir+"/webcam/latest", []byte("../../outside"), 0o644); err != nil {
		t.Fatalf("WriteFile latest: %v", err)
	}

	_, err := s.Get("webcam", "latest")
	if err == nil {
		t.Fatal("Get latest: expected corrupt pointer to be rejected")
	}
	if strings.Contains(err.Error(), "outside") {
		t.Fatalf("Get latest: error should not expose the pointer contents: %v", err)
	}
}

func TestGetUnknownNameReturnsNotFound(t *testing.T) {
	dir := t.TempDir()
	s := NewStorage(dir)
	_, err := s.Get("nope", "latest")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}

func TestGetUnknownVersionReturnsNotFound(t *testing.T) {
	dir := t.TempDir()
	s := NewStorage(dir)
	if err := s.Put("webcam", "v1", []byte("one")); err != nil {
		t.Fatalf("Put: %v", err)
	}
	_, err := s.Get("webcam", "v99")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}

func TestInvalidSegmentsRejected(t *testing.T) {
	dir := t.TempDir()
	s := NewStorage(dir)
	longName := strings.Repeat("a", 256)
	cases := []struct{ name, version string }{
		{"", "v1"},
		{"webcam", ""},
		{"web/cam", "v1"},
		{".", "v1"},
		{"..", "v1"},
		{"webcam", "."},
		{"webcam", ".."},
		{"web cam", "v1"},
		{longName, "v1"},
		{"webcam", longName},
	}
	for _, c := range cases {
		if err := s.Put(c.name, c.version, []byte("x")); err == nil {
			t.Errorf("Put(%q, %q): expected error, got nil", c.name, c.version)
		}
	}
}

// TestOverlongSegmentRejectedAsValidationError は、文字種は正しいが長すぎるセグメントを
// validateSegment 自体で拒否することを確認する（*validationError なので HTTP 400 になる）。
// ファイルシステム層まで通してから ENAMETOOLONG で失敗し、HTTP 500 になることを防ぐ。
func TestOverlongSegmentRejectedAsValidationError(t *testing.T) {
	longName := strings.Repeat("a", 256)
	err := validateSegment(longName)
	if err == nil {
		t.Fatal("expected error for 256-char segment, got nil")
	}
	var ve *validationError
	if !errors.As(err, &ve) {
		t.Fatalf("got error %v (%T), want *validationError", err, err)
	}
}

// TestMaxLengthSegmentAccepted は、255 文字ちょうどは許可し、256 文字以上を
// 拒否する上限が 1 文字ずれていないことを確認する。
func TestMaxLengthSegmentAccepted(t *testing.T) {
	name := strings.Repeat("a", 255)
	if err := validateSegment(name); err != nil {
		t.Fatalf("validateSegment(255 chars): unexpected error: %v", err)
	}
}

func TestPushingLiteralLatestVersionRejected(t *testing.T) {
	dir := t.TempDir()
	s := NewStorage(dir)
	if err := s.Put("webcam", "latest", []byte("x")); err == nil {
		t.Fatal("expected error pushing version \"latest\", got nil")
	}
}

func TestPutIsAtomicNoLeftoverTempFiles(t *testing.T) {
	dir := t.TempDir()
	s := NewStorage(dir)
	if err := s.Put("webcam", "v1", []byte("hello")); err != nil {
		t.Fatalf("Put: %v", err)
	}
	entries, err := os.ReadDir(dir + "/webcam")
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".tmp-") {
			t.Errorf("leftover tmp file: %s", e.Name())
		}
	}
}

func TestListReturnsEmptyMapWhenDataDirMissing(t *testing.T) {
	dir := t.TempDir() + "/does-not-exist"
	s := NewStorage(dir)
	bundles, err := s.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(bundles) != 0 {
		t.Fatalf("got %d bundles, want 0", len(bundles))
	}
}

func TestListReturnsVersionsAndLatest(t *testing.T) {
	dir := t.TempDir()
	s := NewStorage(dir)
	if err := s.Put("webcam", "v1", []byte("one")); err != nil {
		t.Fatalf("Put v1: %v", err)
	}
	if err := s.Put("webcam", "v2", []byte("two")); err != nil {
		t.Fatalf("Put v2: %v", err)
	}
	if err := s.Put("other", "a1", []byte("x")); err != nil {
		t.Fatalf("Put other: %v", err)
	}

	bundles, err := s.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(bundles) != 2 {
		t.Fatalf("got %d bundles, want 2: %+v", len(bundles), bundles)
	}
	webcam := bundles["webcam"]
	if len(webcam.Versions) != 2 || webcam.Versions[0] != "v1" || webcam.Versions[1] != "v2" {
		t.Fatalf("got webcam versions %v, want [v1 v2]", webcam.Versions)
	}
	if webcam.Latest != "v2" {
		t.Fatalf("got webcam latest %q, want v2", webcam.Latest)
	}
	other := bundles["other"]
	if len(other.Versions) != 1 || other.Versions[0] != "a1" {
		t.Fatalf("got other versions %v, want [a1]", other.Versions)
	}
	if other.Latest != "a1" {
		t.Fatalf("got other latest %q, want a1", other.Latest)
	}
}
