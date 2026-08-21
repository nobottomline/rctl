package relay

import (
	"errors"
	"fmt"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/nobottomline/rctl/relay/internal/deb"
)

func loadPublicPackage(name string) ([]byte, deb.Info, error) {
	info, err := os.Lstat(name)
	if err != nil {
		return nil, deb.Info{}, fmt.Errorf("stat %s: %w", name, err)
	}
	if !info.Mode().IsRegular() {
		return nil, deb.Info{}, errors.New("public device package must be a regular file, not a symlink or device")
	}
	if info.Size() <= 0 || info.Size() > deb.MaxPackageBytes {
		return nil, deb.Info{}, fmt.Errorf("public device package size must be between 1 and %d bytes", deb.MaxPackageBytes)
	}
	raw, err := os.ReadFile(name)
	if err != nil {
		return nil, deb.Info{}, fmt.Errorf("read public device package: %w", err)
	}
	packageInfo, err := deb.Inspect(raw)
	if err != nil {
		return nil, deb.Info{}, fmt.Errorf("validate public device package: %w", err)
	}
	return raw, packageInfo, nil
}

func (s *server) handleCreateDevicePackage(w http.ResponseWriter, r *http.Request) {
	if len(s.publicPackage) == 0 {
		writeErr(w, http.StatusServiceUnavailable, "device_package_unavailable")
		return
	}
	if !s.packageMu.TryLock() {
		w.Header().Set("Retry-After", "2")
		writeErr(w, http.StatusTooManyRequests, "device_package_busy")
		return
	}
	defer s.packageMu.Unlock()

	var req struct {
		enrollmentOptions
		DeviceName string `json:"device_name"`
	}
	if err := readStrictJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	name := strings.TrimSpace(req.DeviceName)
	if name == "" {
		name = strings.TrimSpace(req.Label)
	}
	if name == "" {
		name = "iPad"
	}
	validation := deb.Personalization{RelayURL: s.deviceWebSocketURL(), Token: strings.Repeat("x", 32), DeviceName: name}
	if err := validation.Validate(); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_device_package_request")
		return
	}
	enrollment, err := s.createEnrollment(r, req.enrollmentOptions)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "enrollment_create_failed")
		return
	}
	personalized, packageInfo, err := deb.Personalize(s.publicPackage, deb.Personalization{
		RelayURL: s.deviceWebSocketURL(), Token: enrollment.Token, DeviceName: name,
	})
	if err != nil {
		_, _ = s.db.ExecContext(r.Context(), `DELETE FROM enrollments WHERE id=?`, enrollment.ID)
		s.audit(r, "admin_device_package_failed", "enrollment_id", enrollment.ID, "reason", "personalization_failed")
		s.log.Error("personalize device package", "error", err)
		writeErr(w, http.StatusInternalServerError, "device_package_failed")
		return
	}

	filename := fmt.Sprintf("rctl_%s+relay_iphoneos-arm.deb", safeFilenameVersion(packageInfo.Version))
	disposition := mime.FormatMediaType("attachment", map[string]string{"filename": filename})
	w.Header().Set("Content-Type", "application/vnd.debian.binary-package")
	w.Header().Set("Content-Disposition", disposition)
	w.Header().Set("Cache-Control", "no-store, private")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(personalized)))
	w.Header().Set("X-RCTL-Enrollment-ID", enrollment.ID)
	w.WriteHeader(http.StatusCreated)
	written, writeErr := w.Write(personalized)
	if writeErr != nil || written != len(personalized) {
		s.audit(r, "admin_device_package_download_interrupted", "enrollment_id", enrollment.ID)
		return
	}
	s.audit(r, "admin_device_package_created", "enrollment_id", enrollment.ID, "package_version", packageInfo.Version)
}

func safeFilenameVersion(version string) string {
	var out strings.Builder
	for _, char := range version {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') || strings.ContainsRune(".+~_-", char) {
			out.WriteRune(char)
		} else {
			out.WriteByte('_')
		}
	}
	if out.Len() == 0 {
		return "unknown"
	}
	return filepath.Base(out.String())
}
