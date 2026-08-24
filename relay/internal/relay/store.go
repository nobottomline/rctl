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

CREATE TABLE IF NOT EXISTS relay_metadata (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS controller_pairings (
	id TEXT PRIMARY KEY,
	secret_hash TEXT NOT NULL UNIQUE,
	name TEXT NOT NULL,
	scopes_json TEXT NOT NULL,
	expires_at INTEGER NOT NULL,
	used_at INTEGER,
	revoked_at INTEGER,
	created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS controllers (
	id TEXT PRIMARY KEY,
	name TEXT NOT NULL,
	platform TEXT NOT NULL CHECK(platform IN ('ios','android')),
	public_key_der BLOB NOT NULL,
	public_key_sha256 TEXT NOT NULL UNIQUE,
	scopes_json TEXT NOT NULL,
	status TEXT NOT NULL CHECK(status IN ('active','revoked')),
	created_at INTEGER NOT NULL,
	last_seen_at INTEGER,
	revoked_at INTEGER
);

CREATE TABLE IF NOT EXISTS controller_tokens (
	id TEXT PRIMARY KEY,
	controller_id TEXT NOT NULL REFERENCES controllers(id) ON DELETE CASCADE,
	kind TEXT NOT NULL CHECK(kind IN ('access','refresh')),
	secret_hash TEXT NOT NULL,
	expires_at INTEGER NOT NULL,
	created_at INTEGER NOT NULL,
	generation TEXT NOT NULL,
	revoked_at INTEGER
);

CREATE TABLE IF NOT EXISTS controller_nonces (
	controller_id TEXT NOT NULL REFERENCES controllers(id) ON DELETE CASCADE,
	nonce TEXT NOT NULL,
	expires_at INTEGER NOT NULL,
	PRIMARY KEY(controller_id, nonce)
);

CREATE INDEX IF NOT EXISTS idx_devices_status ON devices(status);
CREATE INDEX IF NOT EXISTS idx_enrollments_token_hash ON enrollments(token_hash);
CREATE INDEX IF NOT EXISTS idx_sessions_secret_hash ON sessions(secret_hash);
CREATE INDEX IF NOT EXISTS idx_audit_log_ts ON audit_log(ts);
CREATE INDEX IF NOT EXISTS idx_controller_pairings_expiry ON controller_pairings(expires_at);
CREATE INDEX IF NOT EXISTS idx_controller_tokens_controller ON controller_tokens(controller_id, kind);
CREATE INDEX IF NOT EXISTS idx_controller_tokens_expiry ON controller_tokens(expires_at);
CREATE INDEX IF NOT EXISTS idx_controller_nonces_expiry ON controller_nonces(expires_at);
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
		// navigator.maxTouchPoints (X-RCTL-Touch) — iPadOS Safari sends a macOS
		// User-Agent, so touch capability is the only signal that tells an iPad apart.
		`ALTER TABLE sessions ADD COLUMN touch_points INTEGER`,
		`ALTER TABLE audit_log ADD COLUMN session_id TEXT`,
		`ALTER TABLE devices ADD COLUMN daemon_version TEXT`,
		`ALTER TABLE devices ADD COLUMN browser_version TEXT`,
		`ALTER TABLE devices ADD COLUMN protocol_major INTEGER`,
		`ALTER TABLE devices ADD COLUMN protocol_minor INTEGER`,
		`ALTER TABLE devices ADD COLUMN capabilities_json TEXT`,
		`ALTER TABLE devices ADD COLUMN compatibility_error TEXT`,
	} {
		if _, e := s.db.ExecContext(ctx, stmt); e != nil &&
			!strings.Contains(e.Error(), "duplicate column") {
			return e
		}
	}
	return nil
}
