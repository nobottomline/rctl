package relay

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"database/sql"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nobottomline/rctl/relay/internal/deb"
	_ "modernc.org/sqlite"
)

func TestCreateDevicePackage(t *testing.T) {
	s := newPackageTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/admin/device-package", strings.NewReader(`{"label":"Travel iPad","device_name":"iPad Air"}`))
	recorder := httptest.NewRecorder()
	s.handleCreateDevicePackage(recorder, req)
	response := recorder.Result()
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", response.StatusCode, recorder.Body.String())
	}
	if got := response.Header.Get("Cache-Control"); got != "no-store, private" {
		t.Fatalf("Cache-Control = %q", got)
	}
	if got := response.Header.Get("Content-Disposition"); !strings.Contains(got, "rctl_1.2.3+relay_iphoneos-arm.deb") {
		t.Fatalf("Content-Disposition = %q", got)
	}
	if response.Header.Get("X-RCTL-Enrollment-ID") == "" {
		t.Fatal("response is missing enrollment id")
	}
	if _, err := deb.Inspect(recorder.Body.Bytes()); err == nil || !strings.Contains(err.Error(), "already contains") {
		t.Fatalf("download is not a personalized rctl package: %v", err)
	}
	var count int
	if err := s.db.QueryRow(`SELECT count(*) FROM enrollments`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("enrollment count = %d, err = %v", count, err)
	}
	if strings.Contains(recorder.Body.String(), "enroll_") {
		// The token is intentionally inside compressed package data, never exposed as
		// a response header or JSON field. A raw match would indicate a packaging leak.
		t.Fatal("enrollment token leaked in uncompressed response bytes")
	}
}

func TestCreateDevicePackageFailureDeletesEnrollment(t *testing.T) {
	s := newPackageTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/admin/device-package", strings.NewReader(`{"device_name":"bad\nname"}`))
	recorder := httptest.NewRecorder()
	s.handleCreateDevicePackage(recorder, req)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var count int
	if err := s.db.QueryRow(`SELECT count(*) FROM enrollments`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("failed package left %d enrollment rows: %v", count, err)
	}
}

func TestCreateDevicePackageUnavailableAndBusy(t *testing.T) {
	s := newPackageTestServer(t)
	base := s.publicPackage
	s.publicPackage = nil
	recorder := httptest.NewRecorder()
	s.handleCreateDevicePackage(recorder, httptest.NewRequest(http.MethodPost, "/api/admin/device-package", strings.NewReader(`{}`)))
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("unavailable status = %d", recorder.Code)
	}

	s.publicPackage = base
	s.packageMu.Lock()
	defer s.packageMu.Unlock()
	recorder = httptest.NewRecorder()
	s.handleCreateDevicePackage(recorder, httptest.NewRequest(http.MethodPost, "/api/admin/device-package", strings.NewReader(`{}`)))
	if recorder.Code != http.StatusTooManyRequests || recorder.Header().Get("Retry-After") != "2" {
		t.Fatalf("busy response = %d, Retry-After=%q", recorder.Code, recorder.Header().Get("Retry-After"))
	}
}

func TestDevicePackageRouteRequiresAdminSession(t *testing.T) {
	s := newPackageTestServer(t)
	s.limiter = newRateLimiter(5 * time.Minute)
	mux := http.NewServeMux()
	s.routes(mux)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/api/admin/device-package", strings.NewReader(`{}`)))
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d", recorder.Code)
	}
	var count int
	if err := s.db.QueryRow(`SELECT count(*) FROM enrollments`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("unauthenticated request created enrollment: count=%d err=%v", count, err)
	}
}

func TestLoadPublicPackageRejectsSymlink(t *testing.T) {
	directory := t.TempDir()
	target := filepath.Join(directory, "public.deb")
	if err := os.WriteFile(target, packageFixture(t), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "link.deb")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, _, err := loadPublicPackage(link); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("symlink was accepted: %v", err)
	}
}

func newPackageTestServer(t *testing.T) *server {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	base := packageFixture(t)
	info, err := deb.Inspect(base)
	if err != nil {
		t.Fatal(err)
	}
	s := &server{cfg: config{PublicURL: "https://relay.example.test"}, db: db, log: slog.New(slog.NewTextHandler(io.Discard, nil)), publicPackage: base, publicPackageInfo: info}
	if err := s.migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	return s
}

func packageFixture(t *testing.T) []byte {
	t.Helper()
	control := compressedTarFixture(t, map[string][]byte{"control": []byte("Package: com.greatlove.rctl\nVersion: 1.2.3\nArchitecture: iphoneos-arm\n")})
	data := compressedTarFixture(t, map[string][]byte{"usr/local/bin/rctld": []byte("fixture")})
	var out bytes.Buffer
	out.WriteString("!<arch>\n")
	writeARFixture(t, &out, "debian-binary", []byte("2.0\n"))
	writeARFixture(t, &out, "control.tar.gz", control)
	writeARFixture(t, &out, "data.tar.gz", data)
	return out.Bytes()
}

func compressedTarFixture(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var raw bytes.Buffer
	tw := tar.NewWriter(&raw)
	for name, content := range files {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Typeflag: tar.TypeReg, Size: int64(len(content))}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(content); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	zw := gzip.NewWriter(&out)
	if _, err := io.Copy(zw, &raw); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func writeARFixture(t *testing.T, out *bytes.Buffer, name string, data []byte) {
	t.Helper()
	header := fmt.Sprintf("%-16s%-12d%-6d%-6d%-8s%-10d`\n", name+"/", 0, 0, 0, "100644", len(data))
	if len(header) != 60 {
		t.Fatalf("ar header length = %d", len(header))
	}
	out.WriteString(header)
	out.Write(data)
	if len(data)%2 != 0 {
		out.WriteByte('\n')
	}
}
