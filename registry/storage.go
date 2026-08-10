package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ErrNotFound は、指定された名前が一度も push されていない（そのため
// "latest" を解決できない）か、name/version の tar がディスクにないときに
// Storage.Get が返すエラー。
var ErrNotFound = errors.New("not found")

// validationError は I/O 失敗ではなく、呼び出し元の不正な name/version が原因で
// あることを示す。main.go は errors.As でこれを HTTP 400 に変換する。
type validationError struct {
	msg string
}

func (e *validationError) Error() string { return e.msg }

func newValidationError(format string, args ...any) error {
	return &validationError{msg: fmt.Sprintf(format, args...)}
}

var validSegment = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// maxSegmentLength は name/version のパスセグメントに保守的な上限を設ける。
// 多くのファイルシステムの NAME_MAX（255 バイト）に合わせ、長すぎる入力を
// 後段のファイルシステムエラー（例: ENAMETOOLONG）ではなく、ここで明確な
// HTTP 400 として拒否する。
const maxSegmentLength = 255

// validateSegment は name/version のパスセグメントがファイルシステムの構成要素
// として安全に使えるかを確認する。空でないこと、文字種が限定されていること、
// "." や ".." そのものではないこと、長すぎないことを検査する。
func validateSegment(s string) error {
	if s == "" || !validSegment.MatchString(s) {
		return newValidationError("invalid segment %q", s)
	}
	if s == "." || s == ".." {
		return newValidationError("invalid segment %q", s)
	}
	if len(s) > maxSegmentLength {
		return newValidationError("segment too long (%d bytes, max %d)", len(s), maxSegmentLength)
	}
	return nil
}

// Storage はバンドル tarball を dataDir 以下へ保存する。バンドル名ごとに
// サブディレクトリを作り、直近に push されたバージョン文字列を "latest"
// ポインタファイルへ記録する。
type Storage struct {
	dataDir string
}

func NewStorage(dataDir string) *Storage {
	return &Storage{dataDir: dataDir}
}

func (s *Storage) bundleDir(name string) string {
	return filepath.Join(s.dataDir, name)
}

func (s *Storage) tarPath(name, version string) string {
	return filepath.Join(s.bundleDir(name), version+".tar")
}

func (s *Storage) latestPath(name string) string {
	return filepath.Join(s.bundleDir(name), "latest")
}

// Put は name と version を検証し、<dataDir>/<name>/<version>.tar へ data を
// 原子的に書き込み、<dataDir>/<name>/latest を version に更新する。
func (s *Storage) Put(name, version string, data []byte) error {
	if err := validateSegment(name); err != nil {
		return err
	}
	if err := validateSegment(version); err != nil {
		return err
	}
	if version == "latest" {
		return newValidationError("version %q is reserved", version)
	}
	dir := s.bundleDir(name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := atomicWrite(s.tarPath(name, version), data); err != nil {
		return err
	}
	if err := atomicWrite(s.latestPath(name), []byte(version)); err != nil {
		return err
	}
	return nil
}

// Get は name/version の tar バイト列を返す。version が "latest" の場合は
// latest ポインタファイルで解決する。latest の解決対象となる name が一度も push
// されていない場合、または解決後の tar がない場合は ErrNotFound。
func (s *Storage) Get(name, version string) ([]byte, error) {
	if err := validateSegment(name); err != nil {
		return nil, err
	}
	if err := validateSegment(version); err != nil {
		return nil, err
	}
	if version == "latest" {
		resolved, err := os.ReadFile(s.latestPath(name))
		if err != nil {
			if os.IsNotExist(err) {
				return nil, ErrNotFound
			}
			return nil, err
		}
		version = string(resolved)
		// latest はサーバー内部のポインタファイルから読む値なので、
		// パスを組み立てる前に、Put と同じ制約で再検証する。通常は
		// Put が必ず検証済みの値を書き込むが、手動編集や破損時にも
		// データディレクトリの外へ解決しないようにする。
		if err := validateSegment(version); err != nil {
			return nil, errors.New("invalid latest pointer")
		}
	}
	data, err := os.ReadFile(s.tarPath(name, version))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return data, nil
}

// BundleInfo は読み取り専用の一覧 API 用に、既知のバージョンと解決済みの
// latest バージョンをまとめる。
type BundleInfo struct {
	Versions []string `json:"versions"`
	Latest   string   `json:"latest"`
}

// List は dataDir 直下にある全バンドルについて、既知のバージョン（アルファベット順）
// と解決済み latest を返す。dataDir がまだ存在しない（何も push されていない）場合は
// エラーではなく空の map を返し、新規サーバーの /api/bundles を 500 ではなく 200+{}
// に保つ。
func (s *Storage) List() (map[string]BundleInfo, error) {
	entries, err := os.ReadDir(s.dataDir)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]BundleInfo{}, nil
		}
		return nil, err
	}
	result := make(map[string]BundleInfo)
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		versions, err := s.listVersions(name)
		if err != nil {
			return nil, err
		}
		latest, _ := os.ReadFile(s.latestPath(name))
		result[name] = BundleInfo{Versions: versions, Latest: string(latest)}
	}
	return result, nil
}

// listVersions は指定したバンドル名について、tar ファイル名から .tar を
// 取り除いたバージョン文字列をソートして返す。
func (s *Storage) listVersions(name string) ([]string, error) {
	entries, err := os.ReadDir(s.bundleDir(name))
	if err != nil {
		return nil, err
	}
	var versions []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if strings.HasSuffix(e.Name(), ".tar") {
			versions = append(versions, strings.TrimSuffix(e.Name(), ".tar"))
		}
	}
	sort.Strings(versions)
	return versions, nil
}

// atomicWrite は同じディレクトリに一時ファイルを作り、data を書いて閉じた後に
// 所定の場所へ rename する。途中で失敗した場合は一時ファイルを削除する。
func atomicWrite(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		os.Remove(tmpName)
		return err
	}
	return nil
}
