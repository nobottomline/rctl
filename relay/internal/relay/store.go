package relay

import (
	"context"
	"strings"
)

func (s *server) migrate(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS devices (
	id TEXT PRIMARY KEY,
	name TEXT NOT NULL,
	status TEXT NOT NULL CHECK(status IN ('pending','approved','revoked')),
	device_secret_hash TEXT,
	enroll_token_hash TEXT,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL,
	last_seen_at INTEGER,
	approved_at INTEGER,
	revoked_at INTEGER
);

CREATE TABLE IF NOT EXISTS enrollments (
	id TEXT PRIMARY KEY,
	token_hash TEXT NOT NULL UNIQUE,
	expires_at INTEGER NOT NULL,
	used_at INTEGER,
	created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
	id TEXT PRIMARY KEY,
	secret_hash TEXT NOT NULL,
	expires_at INTEGER NOT NULL,
	created_at INTEGER NOT NULL,
	last_seen_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_log (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	ts INTEGER NOT NULL,
	event TEXT NOT NULL,
	ip TEXT,
	method TEXT,
	path TEXT,
	detail TEXT
);

CREATE INDEX IF NOT EXISTS idx_devices_status ON devices(status);
CREATE INDEX IF NOT EXISTS idx_enrollments_token_hash ON enrollments(token_hash);
CREATE INDEX IF NOT EXISTS idx_sessions_secret_hash ON sessions(secret_hash);
CREATE INDEX IF NOT EXISTS idx_audit_log_ts ON audit_log(ts);
`)
	if err != nil {
		return err
	}
	// Additive column migrations (idempotent: ignore "duplicate column" so this
	// runs cleanly on both fresh and existing databases).
	for _, stmt := range []string{
		`ALTER TABLE enrollments ADD COLUMN label TEXT`,
		`ALTER TABLE enrollments ADD COLUMN revoked_at INTEGER`,
		`ALTER TABLE sessions ADD COLUMN ip TEXT`,
		`ALTER TABLE sessions ADD COLUMN user_agent TEXT`,
		`ALTER TABLE sessions ADD COLUMN client_hints TEXT`,
	} {
		if _, e := s.db.ExecContext(ctx, stmt); e != nil &&
			!strings.Contains(e.Error(), "duplicate column") {
			return e
		}
	}
	return nil
}
