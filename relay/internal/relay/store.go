package relay

import "context"

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

CREATE INDEX IF NOT EXISTS idx_devices_status ON devices(status);
CREATE INDEX IF NOT EXISTS idx_enrollments_token_hash ON enrollments(token_hash);
CREATE INDEX IF NOT EXISTS idx_sessions_secret_hash ON sessions(secret_hash);
`)
	return err
}
