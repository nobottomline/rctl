package relay

import (
	"context"
	"database/sql"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	_ "modernc.org/sqlite"
)

func TestNormalizeDeviceID(t *testing.T) {
	for _, id := range []string{
		"ipad",
		"ipad-air-3",
		"iPad_14.4",
		strings.Repeat("a", maxDeviceIDLength),
	} {
		got, ok := normalizeDeviceID(id)
		if !ok || got != id {
			t.Fatalf("normalizeDeviceID(%q) = %q, %v", id, got, ok)
		}
	}

	for _, id := range []string{
		"bad/id",
		"bad id",
		"bad?id",
		strings.Repeat("a", maxDeviceIDLength+1),
	} {
		if got, ok := normalizeDeviceID(id); ok {
			t.Fatalf("normalizeDeviceID(%q) unexpectedly accepted as %q", id, got)
		}
	}

	got, ok := normalizeDeviceID("")
	if !ok || len(got) != 32 {
		t.Fatalf("normalizeDeviceID(empty) = %q, %v; want generated 32-char hex", got, ok)
	}
}

func TestNormalizeDeviceName(t *testing.T) {
	if got := normalizeDeviceName("  iPad Air  "); got != "iPad Air" {
		t.Fatalf("trimmed name = %q", got)
	}
	if got := normalizeDeviceName(""); got != "Unnamed device" {
		t.Fatalf("empty name = %q", got)
	}
	name := strings.Repeat("п", maxDeviceNameLength+5)
	got := normalizeDeviceName(name)
	if n := len([]rune(got)); n != maxDeviceNameLength {
		t.Fatalf("rune length = %d, want %d", n, maxDeviceNameLength)
	}
	if !utf8.ValidString(got) {
		t.Fatalf("truncated name is not valid UTF-8")
	}
}

func TestAuthenticateDeviceRejectsInvalidClaimedIDWithoutUsingEnrollment(t *testing.T) {
	s, token := newAuthTestServer(t)
	r := httptest.NewRequest("GET", "/device", nil)

	if _, _, err := s.authenticateDevice(r, token, "bad/id", "iPad"); err == nil {
		t.Fatal("authenticateDevice accepted invalid device id")
	}

	var usedAt sql.NullInt64
	if err := s.db.QueryRowContext(context.Background(), `SELECT used_at FROM enrollments`).Scan(&usedAt); err != nil {
		t.Fatal(err)
	}
	if usedAt.Valid {
		t.Fatalf("invalid device id consumed enrollment at %d", usedAt.Int64)
	}

	id, status, err := s.authenticateDevice(r, token, "good-id", "iPad")
	if err != nil {
		t.Fatal(err)
	}
	if id != "good-id" || status != "pending" {
		t.Fatalf("authenticateDevice = %q, %q; want good-id, pending", id, status)
	}
}

func TestAuthenticateDeviceRejectsClaimingExistingApprovedID(t *testing.T) {
	s, token := newAuthTestServer(t)
	now := time.Now().Unix()
	victimSecret := hashToken("dev_victim.secret")
	if _, err := s.db.ExecContext(context.Background(),
		`INSERT INTO devices(id, name, status, device_secret_hash, created_at, updated_at) VALUES(?,?,?,?,?,?)`,
		"victim", "victim", "approved", victimSecret, now, now,
	); err != nil {
		t.Fatal(err)
	}

	r := httptest.NewRequest("GET", "/device", nil)
	if _, _, err := s.authenticateDevice(r, token, "victim", "attacker"); err == nil {
		t.Fatal("enrollment token was allowed to claim an existing approved device id")
	}

	// The victim row must be completely untouched.
	var status, name, secret string
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT status, name, device_secret_hash FROM devices WHERE id=?`, "victim").Scan(&status, &name, &secret); err != nil {
		t.Fatal(err)
	}
	if status != "approved" || name != "victim" || secret != victimSecret {
		t.Fatalf("victim device mutated: status=%q name=%q secret_changed=%v", status, name, secret != victimSecret)
	}

	// A rejected claim must not consume the single-use enrollment token.
	var usedAt sql.NullInt64
	if err := s.db.QueryRowContext(context.Background(), `SELECT used_at FROM enrollments`).Scan(&usedAt); err != nil {
		t.Fatal(err)
	}
	if usedAt.Valid {
		t.Fatal("rejected claim consumed the enrollment token")
	}
}

func newAuthTestServer(t *testing.T) (*server, string) {
	t.Helper()

	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })

	s := &server{db: db}
	if err := s.migrate(context.Background()); err != nil {
		t.Fatal(err)
	}

	tokenID, tokenSecret, err := newTokenPair("enroll")
	if err != nil {
		t.Fatal(err)
	}
	token := tokenID + "." + tokenSecret
	now := time.Now().Unix()
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO enrollments(id, token_hash, expires_at, created_at) VALUES(?,?,?,?)`,
		tokenID, hashToken(token), now+3600, now,
	); err != nil {
		t.Fatal(err)
	}
	return s, token
}
