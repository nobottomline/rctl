package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/crypto/argon2"
	_ "modernc.org/sqlite"
	"nhooyr.io/websocket"
)

type config struct {
	ListenAddr      string
	PublicURL       string
	DatabasePath    string
	AdminSecret     string
	SessionSecret   string
	AllowInsecure   bool
	CookieSecure    bool
	TokenTTL        time.Duration
	ReadLimitBytes  int64
	HeartbeatEvery  time.Duration
	WriteTimeout    time.Duration
	SessionLifetime time.Duration
}

type server struct {
	cfg config
	db  *sql.DB
	log *slog.Logger

	mu      sync.RWMutex
	devices map[string]*deviceConn
}

type deviceConn struct {
	id   string
	name string
	ws   *websocket.Conn

	mu      sync.Mutex
	writeMu sync.Mutex
	viewer  *websocket.Conn
}

type apiError struct {
	Error string `json:"error"`
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "config error: %v\n", err)
		os.Exit(2)
	}

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := os.MkdirAll(filepath.Dir(cfg.DatabasePath), 0o700); err != nil {
		logger.Error("create database dir", "error", err)
		os.Exit(1)
	}

	db, err := sql.Open("sqlite", cfg.DatabasePath)
	if err != nil {
		logger.Error("open database", "error", err)
		os.Exit(1)
	}
	db.SetMaxOpenConns(1)

	s := &server{
		cfg:     cfg,
		db:      db,
		log:     logger,
		devices: make(map[string]*deviceConn),
	}
	if err := s.migrate(context.Background()); err != nil {
		logger.Error("migrate database", "error", err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	s.routes(mux)

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           s.securityHeaders(s.requestLog(mux)),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       0,
		WriteTimeout:      0,
		BaseContext: func(net.Listener) context.Context {
			return context.Background()
		},
	}

	go func() {
		logger.Info("relay listening", "addr", cfg.ListenAddr, "public_url", cfg.PublicURL, "insecure", cfg.AllowInsecure)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(ctx)
	_ = db.Close()
}

func loadConfig() (config, error) {
	cfg := config{
		ListenAddr:      getenv("RCTL_RELAY_LISTEN", ":8080"),
		PublicURL:       getenv("RCTL_RELAY_PUBLIC_URL", "http://localhost:8080"),
		DatabasePath:    getenv("RCTL_RELAY_DB", "./data/rctl-relay.db"),
		AdminSecret:     os.Getenv("RCTL_RELAY_ADMIN_SECRET"),
		SessionSecret:   os.Getenv("RCTL_RELAY_SESSION_SECRET"),
		AllowInsecure:   getenvBool("RCTL_RELAY_ALLOW_INSECURE", false),
		TokenTTL:        getenvDuration("RCTL_RELAY_ENROLL_TTL", 30*time.Minute),
		ReadLimitBytes:  getenvInt64("RCTL_RELAY_READ_LIMIT", 8<<20),
		HeartbeatEvery:  getenvDuration("RCTL_RELAY_HEARTBEAT", 25*time.Second),
		WriteTimeout:    getenvDuration("RCTL_RELAY_WRITE_TIMEOUT", 10*time.Second),
		SessionLifetime: getenvDuration("RCTL_RELAY_SESSION_LIFETIME", 30*24*time.Hour),
	}
	cfg.CookieSecure = strings.HasPrefix(cfg.PublicURL, "https://")
	if cfg.AdminSecret == "" {
		return cfg, errors.New("RCTL_RELAY_ADMIN_SECRET is required")
	}
	if len(cfg.AdminSecret) < 24 {
		return cfg, errors.New("RCTL_RELAY_ADMIN_SECRET must be at least 24 characters")
	}
	if cfg.SessionSecret == "" {
		return cfg, errors.New("RCTL_RELAY_SESSION_SECRET is required")
	}
	if len(cfg.SessionSecret) < 32 {
		return cfg, errors.New("RCTL_RELAY_SESSION_SECRET must be at least 32 characters")
	}
	if !cfg.AllowInsecure && !strings.HasPrefix(cfg.PublicURL, "https://") {
		return cfg, errors.New("RCTL_RELAY_PUBLIC_URL must be https:// in production; set RCTL_RELAY_ALLOW_INSECURE=1 only for local testing")
	}
	return cfg, nil
}

func (s *server) routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /", s.handleRoot)
	mux.HandleFunc("GET /admin", s.handleAdminPage)
	mux.HandleFunc("GET /assets/admin.css", s.handleAdminCSS)
	mux.HandleFunc("GET /assets/admin.js", s.handleAdminJS)
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("POST /api/admin/login", s.handleAdminLogin)
	mux.HandleFunc("POST /api/admin/logout", s.withAdmin(s.handleAdminLogout))
	mux.HandleFunc("GET /api/admin/devices", s.withAdmin(s.handleListDevices))
	mux.HandleFunc("POST /api/admin/enrollments", s.withAdmin(s.handleCreateEnrollment))
	mux.HandleFunc("POST /api/admin/devices/{id}/approve", s.withAdmin(s.handleApproveDevice))
	mux.HandleFunc("POST /api/admin/devices/{id}/revoke", s.withAdmin(s.handleRevokeDevice))
	mux.HandleFunc("GET /device", s.handleDeviceWS)
	mux.HandleFunc("GET /client/devices/{id}", s.withAdmin(s.handleClientWS))
}

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

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleRoot(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/admin", http.StatusFound)
}

func (s *server) handleAdminPage(w http.ResponseWriter, r *http.Request) {
	writeText(w, http.StatusOK, "text/html; charset=utf-8", adminHTML)
}

func (s *server) handleAdminCSS(w http.ResponseWriter, r *http.Request) {
	writeText(w, http.StatusOK, "text/css; charset=utf-8", adminCSS)
}

func (s *server) handleAdminJS(w http.ResponseWriter, r *http.Request) {
	writeText(w, http.StatusOK, "application/javascript; charset=utf-8", adminJS)
}

func (s *server) handleAdminLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Secret string `json:"secret"`
	}
	if err := readJSON(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if subtle.ConstantTimeCompare([]byte(req.Secret), []byte(s.cfg.AdminSecret)) != 1 {
		writeErr(w, http.StatusUnauthorized, "invalid_secret")
		return
	}
	sessionID, sessionSecret, err := newTokenPair("sess")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	now := time.Now()
	_, err = s.db.ExecContext(r.Context(),
		`INSERT INTO sessions(id, secret_hash, expires_at, created_at, last_seen_at) VALUES(?,?,?,?,?)`,
		sessionID, hashToken(sessionSecret), now.Add(s.cfg.SessionLifetime).Unix(), now.Unix(), now.Unix())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "session_create_failed")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "rctl_session",
		Value:    sessionID + "." + sessionSecret,
		Path:     "/",
		HttpOnly: true,
		Secure:   s.cfg.CookieSecure,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   int(s.cfg.SessionLifetime.Seconds()),
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleAdminLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie("rctl_session"); err == nil {
		sessionID, _, ok := strings.Cut(c.Value, ".")
		if ok {
			_, _ = s.db.ExecContext(r.Context(), `DELETE FROM sessions WHERE id=?`, sessionID)
		}
	}
	http.SetCookie(w, &http.Cookie{Name: "rctl_session", Value: "", Path: "/", MaxAge: -1, HttpOnly: true, Secure: s.cfg.CookieSecure, SameSite: http.SameSiteStrictMode})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleCreateEnrollment(w http.ResponseWriter, r *http.Request) {
	tokenID, tokenSecret, err := newTokenPair("enroll")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	now := time.Now()
	_, err = s.db.ExecContext(r.Context(),
		`INSERT INTO enrollments(id, token_hash, expires_at, created_at) VALUES(?,?,?,?)`,
		tokenID, hashToken(tokenSecret), now.Add(s.cfg.TokenTTL).Unix(), now.Unix())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "enrollment_create_failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"token":      tokenID + "." + tokenSecret,
		"expires_at": now.Add(s.cfg.TokenTTL).UTC().Format(time.RFC3339),
		"relay_url":  s.deviceWebSocketURL(),
	})
}

func (s *server) handleListDevices(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), `
SELECT id, name, status, created_at, updated_at, last_seen_at, approved_at, revoked_at
FROM devices
ORDER BY updated_at DESC`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "device_list_failed")
		return
	}
	defer rows.Close()

	type device struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		Status     string `json:"status"`
		Online     bool   `json:"online"`
		CreatedAt  int64  `json:"created_at"`
		UpdatedAt  int64  `json:"updated_at"`
		LastSeenAt *int64 `json:"last_seen_at,omitempty"`
		ApprovedAt *int64 `json:"approved_at,omitempty"`
		RevokedAt  *int64 `json:"revoked_at,omitempty"`
	}
	out := []device{}
	for rows.Next() {
		var d device
		var last, approved, revoked sql.NullInt64
		if err := rows.Scan(&d.ID, &d.Name, &d.Status, &d.CreatedAt, &d.UpdatedAt, &last, &approved, &revoked); err != nil {
			writeErr(w, http.StatusInternalServerError, "device_scan_failed")
			return
		}
		if last.Valid {
			d.LastSeenAt = &last.Int64
		}
		if approved.Valid {
			d.ApprovedAt = &approved.Int64
		}
		if revoked.Valid {
			d.RevokedAt = &revoked.Int64
		}
		d.Online = s.isDeviceOnline(d.ID)
		out = append(out, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

func (s *server) handleApproveDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	deviceSecretID, deviceSecret, err := newTokenPair("dev")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	now := time.Now().Unix()
	res, err := s.db.ExecContext(r.Context(),
		`UPDATE devices SET status='approved', device_secret_hash=?, updated_at=?, approved_at=?, revoked_at=NULL WHERE id=? AND status='pending'`,
		hashToken(deviceSecretID+"."+deviceSecret), now, now, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "device_approve_failed")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "pending_device_not_found")
		return
	}
	s.sendDeviceControl(id, map[string]any{"type": "approved", "device_secret": deviceSecretID + "." + deviceSecret})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleRevokeDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	now := time.Now().Unix()
	_, err := s.db.ExecContext(r.Context(),
		`UPDATE devices SET status='revoked', updated_at=?, revoked_at=? WHERE id=?`,
		now, now, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "device_revoke_failed")
		return
	}
	s.closeDevice(id, websocket.StatusPolicyViolation, "device revoked")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleDeviceWS(w http.ResponseWriter, r *http.Request) {
	token := bearerToken(r)
	if token == "" {
		writeErr(w, http.StatusUnauthorized, "missing_bearer_token")
		return
	}
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: s.cfg.AllowInsecure})
	if err != nil {
		return
	}
	ws.SetReadLimit(s.cfg.ReadLimitBytes)
	defer ws.Close(websocket.StatusInternalError, "server error")

	var hello struct {
		Type       string `json:"type"`
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := wsjsonRead(ctx, ws, &hello); err != nil || hello.Type != "hello" {
		ws.Close(websocket.StatusUnsupportedData, "expected hello")
		return
	}
	if hello.DeviceName == "" {
		hello.DeviceName = "Unnamed device"
	}

	deviceID, status, err := s.authenticateDevice(r.Context(), token, hello.DeviceID, hello.DeviceName)
	if err != nil {
		s.log.Warn("device auth rejected", "error", err)
		ws.Close(websocket.StatusPolicyViolation, "auth rejected")
		return
	}

	dc := &deviceConn{id: deviceID, name: hello.DeviceName, ws: ws}
	s.registerDevice(dc)
	defer s.unregisterDevice(deviceID, dc)
	defer ws.Close(websocket.StatusNormalClosure, "")

	_ = wsjsonWrite(r.Context(), ws, map[string]any{"type": "hello_ack", "device_id": deviceID, "status": status})
	s.log.Info("device connected", "device_id", deviceID, "status", status)
	s.deviceReadLoop(r.Context(), dc)
}

func (s *server) handleClientWS(w http.ResponseWriter, r *http.Request) {
	deviceID := r.PathValue("id")
	dc := s.getDevice(deviceID)
	if dc == nil {
		writeErr(w, http.StatusNotFound, "device_offline")
		return
	}
	if !s.deviceApproved(r.Context(), deviceID) {
		writeErr(w, http.StatusForbidden, "device_not_approved")
		return
	}
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: s.cfg.AllowInsecure})
	if err != nil {
		return
	}
	ws.SetReadLimit(s.cfg.ReadLimitBytes)

	dc.mu.Lock()
	if dc.viewer != nil {
		dc.mu.Unlock()
		ws.Close(websocket.StatusPolicyViolation, "device already has a viewer")
		return
	}
	dc.viewer = ws
	dc.mu.Unlock()

	defer func() {
		dc.mu.Lock()
		if dc.viewer == ws {
			dc.viewer = nil
		}
		dc.mu.Unlock()
		ws.Close(websocket.StatusNormalClosure, "")
	}()

	s.log.Info("client connected", "device_id", deviceID)
	for {
		msgType, payload, err := ws.Read(r.Context())
		if err != nil {
			return
		}
		writeCtx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
		err = dc.write(writeCtx, msgType, payload)
		cancel()
		if err != nil {
			return
		}
	}
}

func (s *server) authenticateDevice(ctx context.Context, token, claimedID, name string) (string, string, error) {
	now := time.Now().Unix()
	tokenHash := hashToken(token)
	var status string
	var deviceID string
	err := s.db.QueryRowContext(ctx, `SELECT id, status FROM devices WHERE device_secret_hash=? AND status='approved'`, tokenHash).Scan(&deviceID, &status)
	if err == nil {
		_, _ = s.db.ExecContext(ctx, `UPDATE devices SET name=?, updated_at=?, last_seen_at=? WHERE id=?`, name, now, now, deviceID)
		return deviceID, status, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", "", err
	}

	var enrollmentID string
	var expiresAt int64
	var usedAt sql.NullInt64
	err = s.db.QueryRowContext(ctx, `SELECT id, expires_at, used_at FROM enrollments WHERE token_hash=?`, tokenHash).Scan(&enrollmentID, &expiresAt, &usedAt)
	if err != nil {
		return "", "", errors.New("invalid token")
	}
	if usedAt.Valid {
		return "", "", errors.New("enrollment already used")
	}
	if expiresAt < now {
		return "", "", errors.New("enrollment expired")
	}

	if claimedID == "" {
		claimedID = randomHex(16)
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO devices(id, name, status, enroll_token_hash, created_at, updated_at, last_seen_at)
VALUES(?, ?, 'pending', ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET name=excluded.name, updated_at=excluded.updated_at, last_seen_at=excluded.last_seen_at
`, claimedID, name, tokenHash, now, now, now)
	if err != nil {
		return "", "", err
	}
	_, _ = s.db.ExecContext(ctx, `UPDATE enrollments SET used_at=? WHERE id=?`, now, enrollmentID)
	return claimedID, "pending", nil
}

func (s *server) deviceReadLoop(ctx context.Context, dc *deviceConn) {
	for {
		msgType, payload, err := dc.ws.Read(ctx)
		if err != nil {
			return
		}
		dc.mu.Lock()
		viewer := dc.viewer
		dc.mu.Unlock()
		if viewer != nil {
			writeCtx, cancel := context.WithTimeout(ctx, s.cfg.WriteTimeout)
			_ = viewer.Write(writeCtx, msgType, payload)
			cancel()
		}
	}
}

func (dc *deviceConn) write(ctx context.Context, msgType websocket.MessageType, payload []byte) error {
	dc.writeMu.Lock()
	defer dc.writeMu.Unlock()
	return dc.ws.Write(ctx, msgType, payload)
}

func (s *server) registerDevice(dc *deviceConn) {
	s.mu.Lock()
	if old := s.devices[dc.id]; old != nil {
		_ = old.ws.Close(websocket.StatusPolicyViolation, "replaced by new connection")
	}
	s.devices[dc.id] = dc
	s.mu.Unlock()
}

func (s *server) unregisterDevice(id string, dc *deviceConn) {
	s.mu.Lock()
	if s.devices[id] == dc {
		delete(s.devices, id)
	}
	s.mu.Unlock()
}

func (s *server) getDevice(id string) *deviceConn {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.devices[id]
}

func (s *server) isDeviceOnline(id string) bool {
	return s.getDevice(id) != nil
}

func (s *server) closeDevice(id string, code websocket.StatusCode, reason string) {
	if dc := s.getDevice(id); dc != nil {
		_ = dc.ws.Close(code, reason)
	}
}

func (s *server) sendDeviceControl(id string, msg map[string]any) {
	if dc := s.getDevice(id); dc != nil {
		payload, err := json.Marshal(msg)
		if err == nil {
			_ = dc.write(context.Background(), websocket.MessageText, payload)
		}
	}
}

func (s *server) deviceApproved(ctx context.Context, id string) bool {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE id=? AND status='approved'`, id).Scan(&n)
	return err == nil && n == 1
}

func (s *server) deviceWebSocketURL() string {
	base := strings.TrimRight(s.cfg.PublicURL, "/")
	switch {
	case strings.HasPrefix(base, "https://"):
		return "wss://" + strings.TrimPrefix(base, "https://") + "/device"
	case strings.HasPrefix(base, "http://"):
		return "ws://" + strings.TrimPrefix(base, "http://") + "/device"
	default:
		return base + "/device"
	}
}

func (s *server) withAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.validSession(r) {
			writeErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r)
	}
}

func (s *server) validSession(r *http.Request) bool {
	c, err := r.Cookie("rctl_session")
	if err != nil {
		return false
	}
	sessionID, secret, ok := strings.Cut(c.Value, ".")
	if !ok || sessionID == "" || secret == "" {
		return false
	}
	now := time.Now().Unix()
	var secretHash string
	var expiresAt int64
	err = s.db.QueryRowContext(r.Context(), `SELECT secret_hash, expires_at FROM sessions WHERE id=?`, sessionID).Scan(&secretHash, &expiresAt)
	if err != nil || expiresAt < now {
		return false
	}
	if subtle.ConstantTimeCompare([]byte(secretHash), []byte(hashToken(secret))) != 1 {
		return false
	}
	_, _ = s.db.ExecContext(r.Context(), `UPDATE sessions SET last_seen_at=? WHERE id=?`, now, sessionID)
	return true
}

func (s *server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		next.ServeHTTP(w, r)
	})
}

func (s *server) requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		s.log.Info("request", "method", r.Method, "path", r.URL.Path, "remote", r.RemoteAddr, "duration_ms", time.Since(start).Milliseconds())
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, apiError{Error: msg})
}

func writeText(w http.ResponseWriter, status int, contentType string, body string) {
	w.Header().Set("Content-Type", contentType)
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}

func readJSON(r *http.Request, v any) error {
	defer r.Body.Close()
	return json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v)
}

func wsjsonRead(ctx context.Context, ws *websocket.Conn, v any) error {
	_, payload, err := ws.Read(ctx)
	if err != nil {
		return err
	}
	return json.Unmarshal(payload, v)
}

func wsjsonWrite(ctx context.Context, ws *websocket.Conn, v any) error {
	payload, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return ws.Write(ctx, websocket.MessageText, payload)
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
}

func newTokenPair(prefix string) (string, string, error) {
	idBytes := make([]byte, 12)
	secretBytes := make([]byte, 32)
	if _, err := rand.Read(idBytes); err != nil {
		return "", "", err
	}
	if _, err := rand.Read(secretBytes); err != nil {
		return "", "", err
	}
	return prefix + "_" + base64.RawURLEncoding.EncodeToString(idBytes), base64.RawURLEncoding.EncodeToString(secretBytes), nil
}

func hashToken(token string) string {
	sum := argon2.IDKey([]byte(token), []byte("rctl-relay-v1"), 1, 64*1024, 4, 32)
	return hex.EncodeToString(sum)
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getenvBool(key string, fallback bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	return v == "1" || strings.EqualFold(v, "true") || strings.EqualFold(v, "yes")
}

func getenvDuration(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return fallback
	}
	return d
}

func getenvInt64(key string, fallback int64) int64 {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return fallback
	}
	return n
}

const adminHTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>rctl relay</title>
  <link rel="stylesheet" href="/assets/admin.css">
</head>
<body>
  <main class="shell">
    <header class="topbar">
      <div>
        <h1>rctl relay</h1>
        <p id="status">Not signed in</p>
      </div>
      <button id="refresh" class="secondary" type="button">Refresh</button>
    </header>

    <section id="loginPanel" class="panel">
      <h2>Admin login</h2>
      <form id="loginForm" class="form">
        <input id="adminSecret" type="password" autocomplete="current-password" placeholder="Admin secret" required>
        <button type="submit">Sign in</button>
      </form>
    </section>

    <section id="appPanel" class="grid hidden">
      <div class="panel">
        <div class="panelHead">
          <h2>Devices</h2>
          <span id="deviceCount" class="muted">0 devices</span>
        </div>
        <div class="tableWrap">
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>Status</th>
                <th>Online</th>
                <th>Updated</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="devices"></tbody>
          </table>
        </div>
      </div>

      <aside class="panel">
        <h2>Enrollment</h2>
        <p class="muted">Create a short-lived token, paste it into relay.env, then run make package-relay.</p>
        <button id="createEnrollment" type="button">Create token</button>
        <textarea id="enrollment" readonly spellcheck="false"></textarea>
      </aside>
    </section>
  </main>
  <script src="/assets/admin.js"></script>
</body>
</html>
`

const adminCSS = `:root{
  color-scheme: light;
  --bg:#f7f8fa;
  --panel:#ffffff;
  --text:#171a1f;
  --muted:#667085;
  --line:#d9dee7;
  --strong:#0f766e;
  --danger:#b42318;
  --shadow:0 10px 30px rgba(18,25,38,.08);
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.shell{width:min(1180px,calc(100vw - 32px));margin:28px auto}
.topbar{display:flex;align-items:center;justify-content:space-between;margin-bottom:18px}
h1,h2,p{margin:0}
h1{font-size:24px;font-weight:700}
h2{font-size:15px;font-weight:700}
.topbar p,.muted{color:var(--muted)}
.grid{display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:16px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:8px;box-shadow:var(--shadow);padding:16px}
.panelHead{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}
.form{display:flex;gap:10px;margin-top:12px}
input,textarea{width:100%;border:1px solid var(--line);border-radius:6px;background:white;color:var(--text);font:inherit;padding:10px 11px}
textarea{height:190px;margin-top:12px;resize:vertical;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
button{border:0;border-radius:6px;background:var(--strong);color:white;font-weight:700;padding:10px 13px;cursor:pointer;white-space:nowrap}
button.secondary{background:#344054}
button.danger{background:var(--danger)}
button:disabled{opacity:.55;cursor:not-allowed}
.tableWrap{overflow:auto;border:1px solid var(--line);border-radius:6px}
table{width:100%;border-collapse:collapse;background:white}
th,td{padding:10px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:middle}
th{font-size:12px;color:var(--muted);font-weight:700;background:#fbfcfe}
tr:last-child td{border-bottom:0}
.pill{display:inline-flex;align-items:center;border-radius:999px;padding:3px 8px;font-size:12px;font-weight:700;background:#eef4ff;color:#3538cd}
.pill.approved{background:#ecfdf3;color:#027a48}
.pill.revoked{background:#fef3f2;color:#b42318}
.empty{color:var(--muted);text-align:center;padding:24px}
.hidden{display:none}
@media (max-width: 820px){
  .shell{width:min(100vw - 20px,1180px);margin:14px auto}
  .topbar,.form{align-items:stretch;flex-direction:column}
  .grid{grid-template-columns:1fr}
}
`

const adminJS = `const state = { signedIn: false };
const $ = (id) => document.getElementById(id);

function setStatus(text) { $("status").textContent = text; }
function showApp(show) {
  $("loginPanel").classList.toggle("hidden", show);
  $("appPanel").classList.toggle("hidden", !show);
  state.signedIn = show;
}
async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", ...(options.headers || {}) }
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || res.statusText);
  return body;
}
function fmtTime(sec) {
  if (!sec) return "";
  return new Date(sec * 1000).toLocaleString();
}
function rowActions(device) {
  if (device.status === "pending") {
    return '<button data-action="approve" data-id="' + device.id + '">Approve</button>';
  }
  if (device.status !== "revoked") {
    return '<button class="danger" data-action="revoke" data-id="' + device.id + '">Revoke</button>';
  }
  return "";
}
async function refreshDevices() {
  const data = await api("/api/admin/devices");
  const devices = data.devices || [];
  $("deviceCount").textContent = devices.length + (devices.length === 1 ? " device" : " devices");
  $("devices").innerHTML = devices.length ? devices.map((d) =>
    '<tr>' +
      '<td><strong>' + escapeHTML(d.name) + '</strong><br><span class="muted">' + escapeHTML(d.id) + '</span></td>' +
      '<td><span class="pill ' + escapeHTML(d.status) + '">' + escapeHTML(d.status) + '</span></td>' +
      '<td>' + (d.online ? "online" : "offline") + '</td>' +
      '<td>' + fmtTime(d.updated_at) + '</td>' +
      '<td>' + rowActions(d) + '</td>' +
    '</tr>'
  ).join("") : '<tr><td colspan="5" class="empty">No devices yet</td></tr>';
  setStatus("Signed in");
}
function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));
}
$("loginForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    await api("/api/admin/login", { method: "POST", body: JSON.stringify({ secret: $("adminSecret").value }) });
    $("adminSecret").value = "";
    showApp(true);
    await refreshDevices();
  } catch (err) {
    setStatus("Login failed: " + err.message);
  }
});
$("refresh").addEventListener("click", async () => {
  if (!state.signedIn) return;
  try { await refreshDevices(); } catch (err) { setStatus("Refresh failed: " + err.message); }
});
$("createEnrollment").addEventListener("click", async () => {
  try {
    const data = await api("/api/admin/enrollments", { method: "POST" });
    $("enrollment").value = "RELAY_URL=" + data.relay_url + "\nENROLL_TOKEN=" + data.token + "\n";
  } catch (err) {
    setStatus("Enrollment failed: " + err.message);
  }
});
$("devices").addEventListener("click", async (event) => {
  const button = event.target.closest("button[data-action]");
  if (!button) return;
  button.disabled = true;
  try {
    await api("/api/admin/devices/" + encodeURIComponent(button.dataset.id) + "/" + button.dataset.action, { method: "POST" });
    await refreshDevices();
  } catch (err) {
    setStatus(button.dataset.action + " failed: " + err.message);
  } finally {
    button.disabled = false;
  }
});
`
