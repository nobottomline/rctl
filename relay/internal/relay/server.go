package relay

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
)

type server struct {
	cfg config
	db  *sql.DB
	log *slog.Logger

	mu      sync.RWMutex
	devices map[string]*deviceConn
	limiter *rateLimiter
}

func Run() {
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
		limiter: newRateLimiter(5 * time.Minute),
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

func (s *server) routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /", s.handleRoot)
	mux.HandleFunc("GET /admin", s.handleAdminPage)
	mux.HandleFunc("GET /assets/admin.css", s.handleAdminCSS)
	mux.HandleFunc("GET /assets/admin.js", s.handleAdminJS)
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("POST /api/admin/login", s.withRateLimit("login", s.cfg.LoginLimit, s.handleAdminLogin))
	mux.HandleFunc("POST /api/admin/logout", s.withAdmin(s.handleAdminLogout))
	mux.HandleFunc("GET /api/admin/devices", s.withAdmin(s.handleListDevices))
	mux.HandleFunc("POST /api/admin/enrollments", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleCreateEnrollment)))
	mux.HandleFunc("POST /api/admin/devices/{id}/approve", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleApproveDevice)))
	mux.HandleFunc("POST /api/admin/devices/{id}/revoke", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleRevokeDevice)))
	mux.HandleFunc("GET /device", s.withRateLimit("device", s.cfg.DeviceLimit, s.handleDeviceWS))
	mux.HandleFunc("GET /client/devices/{id}", s.withAdmin(s.handleClientWS))
}
