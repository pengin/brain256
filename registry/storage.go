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

// ErrNotFound is returned by Storage.Get when the requested name has never
// been pushed (so "latest" can't resolve), or the name/version tar doesn't
// exist on disk.
var ErrNotFound = errors.New("not found")

// validationError marks an error as caused by bad caller input (invalid
// name/version), as opposed to an I/O failure. main.go uses errors.As to
// map this to HTTP 400 instead of 500.
type validationError struct {
	msg string
}

func (e *validationError) Error() string { return e.msg }

func newValidationError(format string, args ...any) error {
	return &validationError{msg: fmt.Sprintf(format, args...)}
}

var validSegment = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// maxSegmentLength caps name/version path segments at a conservative,
// common filesystem-component limit (matching the 255-byte NAME_MAX on
// most filesystems), so overlong input is rejected here with a clean 400
// instead of surfacing later as a filesystem-level error (e.g. ENAMETOOLONG).
const maxSegmentLength = 255

// validateSegment checks that a name/version path segment is safe to use
// as a filesystem path component: non-empty, restricted charset, not
// literally "." or ".." (the charset alone permits both, since "." and "-"
// are individually allowed), and not too long.
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

// Storage persists bundle tarballs under dataDir, one subdirectory per
// bundle name, with a "latest" pointer file recording the most recently
// pushed version string.
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

// Put validates name and version, then atomically writes data to
// <dataDir>/<name>/<version>.tar and updates <dataDir>/<name>/latest to
// point at version.
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

// Get returns the tar bytes for name/version. If version is "latest", it is
// first resolved via the latest pointer file. Returns ErrNotFound if name
// has never been pushed (when resolving "latest") or the resolved
// name/version tar does not exist.
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

// BundleInfo summarizes one bundle's known versions and its resolved
// latest version, for the read-only listing API.
type BundleInfo struct {
	Versions []string `json:"versions"`
	Latest   string   `json:"latest"`
}

// List returns every bundle currently under dataDir, each with its known
// versions (sorted alphabetically) and resolved latest version. Returns an
// empty map, not an error, if dataDir does not exist yet (nothing has ever
// been pushed) -- this keeps /api/bundles a clean 200+{} on a fresh server
// instead of a 500.
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

// listVersions returns the sorted version strings (tar filenames with the
// .tar suffix stripped) for one bundle name.
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

// atomicWrite writes data to path by creating a temp file in the same
// directory, writing and closing it, then renaming it into place. On any
// failure the temp file is removed.
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
