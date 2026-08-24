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

	"github.com/nobottomline/rctl/relay/internal/deb"
)

// Version is the build version, overridable via -ldflags "-X ...relay.Version=...".
var Version = "dev"

type server struct {
	cfg config
	db  *sql.DB
	log *slog.Logger

	startedAt time.Time

	mu      sync.RWMutex
	devices map[string]*deviceConn
	limiter *rateLimiter

	packageMu         sync.Mutex
	publicPackage     []byte
	publicPackageInfo deb.Info
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
		cfg:       cfg,
		db:        db,
		log:       logger,
		startedAt: time.Now(),
		devices:   make(map[string]*deviceConn),
		limiter:   newRateLimiter(5 * time.Minute),
	}
	if cfg.PublicPackagePath != "" {
		packageData, packageInfo, err := loadPublicPackage(cfg.PublicPackagePath)
		if err != nil {
			logger.Error("load public device package", "error", err)
			os.Exit(1)
		}
		s.publicPackage = packageData
		s.publicPackageInfo = packageInfo
		logger.Info("public device package ready", "version", packageInfo.Version, "format", packageInfo.DataFormat)
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
	mux.HandleFunc("GET /admin", s.handleAdminRoot)
	mux.Handle("GET /admin/{path...}", s.handleAdminAssets())
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /v1/capabilities", s.handleCapabilities)
	mux.HandleFunc("POST /api/admin/login", s.withRateLimit("login", s.cfg.LoginLimit, s.handleAdminLogin))
	mux.HandleFunc("POST /api/admin/logout", s.withAdmin(s.handleAdminLogout))
	mux.HandleFunc("GET /api/admin/status", s.withAdmin(s.handleStatus))
	mux.HandleFunc("GET /api/admin/sessions", s.withAdmin(s.handleListSessions))
	mux.HandleFunc("GET /api/admin/audit", s.withAdmin(s.handleListAudit))
	mux.HandleFunc("POST /api/admin/sessions/revoke-others", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleRevokeOtherSessions)))
	mux.HandleFunc("POST /api/admin/sessions/revoke-all", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleRevokeAllSessions)))
	mux.HandleFunc("POST /api/admin/sessions/{id}/revoke", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleRevokeSession)))
	mux.HandleFunc("POST /api/admin/controller-pairings", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleCreateControllerPairing)))
	mux.HandleFunc("GET /api/admin/controllers", s.withAdmin(s.handleListControllers))
	mux.HandleFunc("POST /api/admin/controllers/{id}/rename", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleRenameController)))
	mux.HandleFunc("POST /api/admin/controllers/{id}/revoke", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleRevokeController)))
	mux.HandleFunc("GET /api/admin/devices", s.withAdmin(s.handleListDevices))
	mux.HandleFunc("GET /api/admin/enrollments", s.withAdmin(s.handleListEnrollments))
	mux.HandleFunc("POST /api/admin/enrollments", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleCreateEnrollment)))
	mux.HandleFunc("POST /api/admin/device-package", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleCreateDevicePackage)))
	mux.HandleFunc("POST /api/admin/enrollments/{id}/revoke", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleRevokeEnrollment)))
	mux.HandleFunc("POST /api/admin/enrollments/{id}/delete", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleDeleteEnrollment)))
	mux.HandleFunc("POST /api/admin/devices/{id}/approve", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleApproveDevice)))
	mux.HandleFunc("POST /api/admin/devices/{id}/revoke", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleRevokeDevice)))
	mux.HandleFunc("POST /api/admin/devices/{id}/delete", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleDeleteDevice)))
	mux.HandleFunc("POST /api/admin/devices/{id}/update", s.withAdmin(s.withRateLimit("admin", s.cfg.AdminLimit, s.handleUpdateDevice)))
	mux.HandleFunc("GET /proxy/devices/{id}/{path...}", s.withAdmin(s.withRateLimit("tunnel", s.cfg.TunnelLimit, s.handleTunnelHTTP)))
	mux.HandleFunc("POST /proxy/devices/{id}/{path...}", s.withAdmin(s.withRateLimit("tunnel", s.cfg.TunnelLimit, s.handleTunnelHTTP)))
	mux.HandleFunc("PUT /proxy/devices/{id}/{path...}", s.withAdmin(s.withRateLimit("tunnel", s.cfg.TunnelLimit, s.handleTunnelHTTP)))
	mux.HandleFunc("PATCH /proxy/devices/{id}/{path...}", s.withAdmin(s.withRateLimit("tunnel", s.cfg.TunnelLimit, s.handleTunnelHTTP)))
	mux.HandleFunc("DELETE /proxy/devices/{id}/{path...}", s.withAdmin(s.withRateLimit("tunnel", s.cfg.TunnelLimit, s.handleTunnelHTTP)))
	mux.HandleFunc("GET /stream/devices/{id}/{path...}", s.withAdmin(s.withRateLimit("tunnel", s.cfg.TunnelLimit, s.handleTunnelStream)))
	mux.HandleFunc("GET /term/devices/{id}", s.withAdmin(s.withRateLimit("tunnel", s.cfg.TunnelLimit, s.handleTunnelTermWS)))
	mux.HandleFunc("GET /signal/devices/{id}", s.withAdmin(s.withRateLimit("tunnel", s.cfg.TunnelLimit, s.handleSignalWS)))
	mux.HandleFunc("GET /device", s.withRateLimit("device", s.cfg.DeviceLimit, s.handleDeviceWS))
	mux.HandleFunc("GET /device-streams/{streamID}", s.withRateLimit("device", s.cfg.DeviceLimit, s.handleDeviceStreamWS))
	mux.HandleFunc("POST /api/controller/pairings/{id}/claim", s.withRateLimit("controller", s.cfg.ControllerLimit, s.handleClaimControllerPairing))
	mux.HandleFunc("POST /api/controller/token/refresh", s.withRateLimit("controller", s.cfg.ControllerLimit, s.withControllerToken("refresh", s.handleRefreshControllerToken)))
	mux.HandleFunc("GET /api/controller/me", s.withRateLimit("controller", s.cfg.ControllerLimit, s.withControllerToken("access", s.handleControllerMe)))
	mux.HandleFunc("GET /client/devices/{id}", s.withAdmin(s.handleClientWS))
	mux.HandleFunc("GET /control/devices/{id}", s.withAdmin(s.handleControlPage))
}
