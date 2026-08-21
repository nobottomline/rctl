package setup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	backupSchema   = 1
	maxBackupBytes = int64(4 << 30)
)

type BackupEntry struct {
	Path   string `json:"path"`
	Type   string `json:"type"`
	Mode   uint32 `json:"mode"`
	Size   int64  `json:"size,omitempty"`
	SHA256 string `json:"sha256,omitempty"`
	UID    uint32 `json:"uid"`
	GID    uint32 `json:"gid"`
}

type BackupMetadata struct {
	Schema    int           `json:"schema"`
	Product   string        `json:"product"`
	CreatedAt int64         `json:"created_at"`
	Release   string        `json:"release"`
	Config    Config        `json:"config"`
	Entries   []BackupEntry `json:"entries"`
}

type BackupManager struct {
	Paths    Paths
	Runner   Runner
	Verifier PublicVerifier
	Now      func() time.Time
}

func (b BackupManager) DryRun() ([]string, error) {
	if b.Paths.EtcDir == "" {
		b.Paths = DefaultPaths()
	}
	if err := ensureNoPendingRecovery(b.Paths); err != nil {
		return nil, err
	}
	installed, err := loadManifest(b.Paths.ManifestPath)
	if err != nil {
		return nil, err
	}
	if err := validateOwnershipManifest(installed, b.Paths); err != nil {
		return nil, err
	}
	if err := verifyOwnedFiles(installed); err != nil {
		return nil, err
	}
	sources := snapshotSources(installed, b.Paths)
	total := int64(0)
	for _, source := range sources {
		if err := inspectSnapshotPath(source, &total); err != nil {
			return nil, err
		}
	}
	return sources, nil
}

func (b BackupManager) Create(ctx context.Context) (result string, err error) {
	if b.Paths.EtcDir == "" {
		b.Paths = DefaultPaths()
	}
	if b.Runner == nil {
		b.Runner = OSRunner{}
	}
	if b.Verifier == nil {
		b.Verifier = HTTPSVerifier{}
	}
	if b.Now == nil {
		b.Now = time.Now
	}
	releaseLock, err := acquireLifecycleLock(b.Paths.LockPath)
	if err != nil {
		return "", err
	}
	defer releaseLock()
	if err := ensureNoPendingRecovery(b.Paths); err != nil {
		return "", err
	}

	installed, err := loadManifest(b.Paths.ManifestPath)
	if err != nil {
		return "", err
	}
	if err := validateOwnershipManifest(installed, b.Paths); err != nil {
		return "", err
	}
	if err := verifyOwnedFiles(installed); err != nil {
		return "", err
	}
	secrets, err := readExistingSecrets(b.Paths.RelayEnv)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(b.Paths.BackupDir, 0o700); err != nil {
		return "", fmt.Errorf("create backup directory: %w", err)
	}
	if err := os.Chmod(b.Paths.BackupDir, 0o700); err != nil {
		return "", err
	}
	candidate, err := os.MkdirTemp(b.Paths.BackupDir, ".backup-")
	if err != nil {
		return "", err
	}
	if err := os.Chmod(candidate, 0o700); err != nil {
		_ = os.RemoveAll(candidate)
		return "", err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(candidate)
		}
	}()

	installer := Installer{Paths: b.Paths, Runner: b.Runner, Verifier: b.Verifier}
	if err := beginRecovery(b.Paths, "backup", "", b.Now()); err != nil {
		return "", err
	}
	if output, stopErr := b.Runner.Run(ctx, "docker", installer.composeArgs("stop", "relay", "caddy")...); stopErr != nil {
		return "", fmt.Errorf("stop services for consistent backup: %s", commandFailure(output, stopErr))
	}
	servicesStopped := true
	defer func() {
		if servicesStopped {
			recoveryContext, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
			defer cancel()
			if _, restartErr := b.Runner.Run(recoveryContext, "docker", installer.composeArgs("up", "-d", "relay", "caddy")...); restartErr == nil {
				if waitErr := installer.waitForServices(recoveryContext, installed.Config.EnableTURN); waitErr == nil {
					if verifyErr := b.Verifier.Verify(recoveryContext, installed.Config, secrets.Admin); verifyErr == nil {
						_ = clearRecovery(b.Paths)
					}
				}
			}
		}
	}()

	entries := make([]BackupEntry, 0)
	total := int64(0)
	backupRoot := filepath.Join(candidate, "root")
	for _, source := range snapshotSources(installed, b.Paths) {
		destination := filepath.Join(backupRoot, strings.TrimPrefix(source, string(filepath.Separator)))
		if err := copySnapshotPath(source, destination, backupRoot, &entries, &total); err != nil {
			return "", err
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Path < entries[j].Path })
	metadata := BackupMetadata{Schema: backupSchema, Product: "rctl", CreatedAt: b.Now().Unix(), Release: installed.Version, Config: installed.Config, Entries: entries}
	if err := writeJSONAtomic(filepath.Join(candidate, "backup.json"), metadata, 0o600); err != nil {
		return "", err
	}
	if err := syncDirectory(candidate); err != nil {
		return "", err
	}
	if _, err := ValidateBackup(candidate); err != nil {
		return "", fmt.Errorf("validate candidate backup: %w", err)
	}

	if output, startErr := b.Runner.Run(ctx, "docker", installer.composeArgs("up", "-d", "relay", "caddy")...); startErr != nil {
		return "", fmt.Errorf("restart services after backup: %s", commandFailure(output, startErr))
	}
	servicesStopped = false
	if err := installer.waitForServices(ctx, installed.Config.EnableTURN); err != nil {
		return "", err
	}
	if err := b.Verifier.Verify(ctx, installed.Config, secrets.Admin); err != nil {
		return "", fmt.Errorf("post-backup verification: %w", err)
	}
	if err := clearRecovery(b.Paths); err != nil {
		return "", fmt.Errorf("commit backup recovery checkpoint: %w", err)
	}

	stamp := b.Now().UTC().Format("20060102T150405Z")
	final := filepath.Join(b.Paths.BackupDir, "backup-"+stamp+"-"+safeLifecycleName(installed.Version))
	if _, err := os.Lstat(final); err == nil {
		return "", fmt.Errorf("backup destination already exists: %s", final)
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err := os.Rename(candidate, final); err != nil {
		return "", err
	}
	if err := syncDirectory(b.Paths.BackupDir); err != nil {
		return "", err
	}
	committed = true
	return final, nil
}

func snapshotSources(manifest OwnershipManifest, paths Paths) []string {
	sources := []string{paths.DataDir}
	for _, file := range manifest.Files {
		if file.Path == paths.ManifestPath || pathWithin(file.Path, paths.DataDir) {
			continue
		}
		sources = append(sources, file.Path)
	}
	sort.Strings(sources)
	return sources
}

func copySnapshotPath(source, destination, backupRoot string, entries *[]BackupEntry, total *int64) error {
	return filepath.WalkDir(source, func(name string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		info, err := item.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || (!info.Mode().IsRegular() && !info.IsDir()) {
			return fmt.Errorf("backup refuses non-regular path %s", name)
		}
		relative, err := filepath.Rel(source, name)
		if err != nil {
			return err
		}
		target := destination
		if relative != "." {
			target = filepath.Join(destination, relative)
		}
		if !pathWithin(target, backupRoot) {
			return fmt.Errorf("backup path escapes snapshot root: %s", target)
		}
		stored, err := filepath.Rel(backupRoot, target)
		if err != nil || stored == "." || strings.HasPrefix(stored, "..") {
			return fmt.Errorf("invalid backup path %s", target)
		}
		uid, gid, err := fileOwnership(info)
		if err != nil {
			return err
		}
		entry := BackupEntry{Path: filepath.ToSlash(stored), Mode: uint32(info.Mode().Perm()), UID: uid, GID: gid}
		if info.IsDir() {
			entry.Type = "dir"
			if err := os.MkdirAll(target, info.Mode().Perm()); err != nil {
				return err
			}
			if err := os.Chmod(target, info.Mode().Perm()); err != nil {
				return err
			}
			if err := os.Chown(target, int(uid), int(gid)); err != nil {
				return err
			}
			*entries = append(*entries, entry)
			return nil
		}
		*total += info.Size()
		if *total > maxBackupBytes {
			return errors.New("backup exceeds the size limit")
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return err
		}
		digest, err := copyRegularFile(name, target, info.Mode().Perm(), int(uid), int(gid))
		if err != nil {
			return err
		}
		entry.Type, entry.Size, entry.SHA256 = "file", info.Size(), digest
		*entries = append(*entries, entry)
		return nil
	})
}

func inspectSnapshotPath(source string, total *int64) error {
	return filepath.WalkDir(source, func(name string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		info, err := item.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || (!info.Mode().IsRegular() && !info.IsDir()) {
			return fmt.Errorf("backup refuses non-regular path %s", name)
		}
		if info.Mode().IsRegular() {
			*total += info.Size()
			if *total > maxBackupBytes {
				return errors.New("backup exceeds the size limit")
			}
		}
		return nil
	})
}

func copyRegularFile(source, destination string, mode os.FileMode, uid, gid int) (string, error) {
	in, err := os.Open(source)
	if err != nil {
		return "", err
	}
	defer in.Close()
	out, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(out, hash), in)
	if copyErr == nil {
		copyErr = out.Sync()
	}
	closeErr := out.Close()
	if copyErr != nil {
		return "", copyErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	if err := os.Chown(destination, uid, gid); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func fileOwnership(info os.FileInfo) (uint32, uint32, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, errors.New("filesystem did not provide Unix ownership metadata")
	}
	return stat.Uid, stat.Gid, nil
}

func pathWithin(name, root string) bool {
	relative, err := filepath.Rel(filepath.Clean(root), filepath.Clean(name))
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func syncDirectory(name string) error {
	directory, err := os.Open(name)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func safeLifecycleName(value string) string {
	var out strings.Builder
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') || strings.ContainsRune("._+-", char) {
			out.WriteRune(char)
		} else {
			out.WriteByte('_')
		}
	}
	if out.Len() == 0 {
		return "unknown"
	}
	return out.String()
}

func loadBackupMetadata(name string) (BackupMetadata, error) {
	var metadata BackupMetadata
	raw, err := readRegularFile(filepath.Join(name, "backup.json"), 16<<20, 0o600)
	if err != nil {
		return metadata, err
	}
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&metadata); err != nil {
		return metadata, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return metadata, errors.New("backup metadata contains trailing data")
	}
	if metadata.Schema != backupSchema || metadata.Product != "rctl" || metadata.CreatedAt <= 0 || metadata.Release == "" {
		return metadata, errors.New("backup metadata is incompatible")
	}
	if err := metadata.Config.Validate(); err != nil {
		return metadata, err
	}
	return metadata, nil
}

func ValidateBackup(name string) (BackupMetadata, error) {
	var empty BackupMetadata
	info, err := os.Lstat(name)
	if err != nil {
		return empty, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o700 {
		return empty, errors.New("backup must be a mode-0700 directory, not a symlink")
	}
	metadata, err := loadBackupMetadata(name)
	if err != nil {
		return empty, err
	}
	root := filepath.Join(name, "root")
	expected := make(map[string]BackupEntry, len(metadata.Entries))
	parents := make(map[string]bool)
	last := ""
	total := int64(0)
	for _, entry := range metadata.Entries {
		clean := filepath.ToSlash(filepath.Clean(filepath.FromSlash(entry.Path)))
		if entry.Path == "" || clean != entry.Path || strings.HasPrefix(clean, "../") || clean == ".." || filepath.IsAbs(entry.Path) || entry.Path <= last {
			return empty, fmt.Errorf("backup metadata contains invalid or unsorted path %q", entry.Path)
		}
		if entry.Type != "file" && entry.Type != "dir" {
			return empty, fmt.Errorf("backup metadata contains invalid type for %s", entry.Path)
		}
		if entry.Mode > 0o777 || (entry.Type == "file" && (entry.Size < 0 || len(entry.SHA256) != sha256.Size*2)) || (entry.Type == "dir" && (entry.Size != 0 || entry.SHA256 != "")) {
			return empty, fmt.Errorf("backup metadata contains invalid file attributes for %s", entry.Path)
		}
		if entry.Type == "file" {
			if _, err := hex.DecodeString(entry.SHA256); err != nil {
				return empty, fmt.Errorf("backup metadata contains invalid digest for %s", entry.Path)
			}
			if entry.Size > maxBackupBytes-total {
				return empty, errors.New("backup exceeds the aggregate size limit")
			}
			total += entry.Size
		}
		expected[entry.Path] = entry
		for parent := filepath.ToSlash(filepath.Dir(filepath.FromSlash(entry.Path))); parent != "." && parent != "/"; parent = filepath.ToSlash(filepath.Dir(filepath.FromSlash(parent))) {
			parents[parent] = true
		}
		last = entry.Path
	}
	seen := make(map[string]bool, len(expected))
	err = filepath.WalkDir(root, func(pathName string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if pathName == root {
			return nil
		}
		relative, err := filepath.Rel(root, pathName)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		expectedEntry, ok := expected[relative]
		if !ok {
			if item.IsDir() && parents[relative] {
				return nil
			}
			return fmt.Errorf("backup contains unlisted path %s", relative)
		}
		info, err := item.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || (!info.IsDir() && !info.Mode().IsRegular()) {
			return fmt.Errorf("backup contains unsafe path %s", relative)
		}
		kind := "file"
		if info.IsDir() {
			kind = "dir"
		}
		uid, gid, err := fileOwnership(info)
		if err != nil {
			return err
		}
		if kind != expectedEntry.Type || uint32(info.Mode().Perm()) != expectedEntry.Mode || uid != expectedEntry.UID || gid != expectedEntry.GID {
			return fmt.Errorf("backup attributes differ for %s", relative)
		}
		if kind == "file" {
			size, digest, err := hashRegularFile(pathName, maxBackupBytes)
			if err != nil {
				return err
			}
			if size != expectedEntry.Size || digest != expectedEntry.SHA256 {
				return fmt.Errorf("backup digest differs for %s", relative)
			}
		}
		seen[relative] = true
		return nil
	})
	if err != nil {
		return empty, err
	}
	if len(seen) != len(expected) {
		return empty, errors.New("backup is missing one or more declared paths")
	}
	return metadata, nil
}

func hashRegularFile(name string, maximum int64) (int64, string, error) {
	info, err := os.Lstat(name)
	if err != nil {
		return 0, "", err
	}
	if !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > maximum {
		return 0, "", errors.New("file is not regular or exceeds size limit")
	}
	file, err := os.Open(name)
	if err != nil {
		return 0, "", err
	}
	defer file.Close()
	hash := sha256.New()
	written, err := io.Copy(hash, io.LimitReader(file, maximum+1))
	if err != nil || written != info.Size() {
		return 0, "", errors.New("file changed or could not be hashed")
	}
	return written, hex.EncodeToString(hash.Sum(nil)), nil
}
