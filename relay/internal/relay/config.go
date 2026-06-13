package relay

import (
	"errors"
	"os"
	"strconv"
	"strings"
	"time"
)

type config struct {
	ListenAddr         string
	PublicURL          string
	DatabasePath       string
	WebDir             string
	AdminSecret        string
	SessionSecret      string
	AllowInsecure      bool
	CookieSecure       bool
	TokenTTL           time.Duration
	ReadLimitBytes     int64
	HeartbeatEvery     time.Duration
	WriteTimeout       time.Duration
	SessionLifetime    time.Duration
	TunnelTimeout      time.Duration
	TunnelMaxBody      int64
	StreamStartTimeout time.Duration
	LoginLimit         rateLimitConfig
	AdminLimit         rateLimitConfig
	DeviceLimit        rateLimitConfig
	TunnelLimit        rateLimitConfig
}

func loadConfig() (config, error) {
	cfg := config{
		ListenAddr:         getenv("RCTL_RELAY_LISTEN", ":8080"),
		PublicURL:          getenv("RCTL_RELAY_PUBLIC_URL", "http://localhost:8080"),
		DatabasePath:       getenv("RCTL_RELAY_DB", "./data/rctl-relay.db"),
		WebDir:             getenv("RCTL_RELAY_WEB_DIR", "../web"),
		AdminSecret:        os.Getenv("RCTL_RELAY_ADMIN_SECRET"),
		SessionSecret:      os.Getenv("RCTL_RELAY_SESSION_SECRET"),
		AllowInsecure:      getenvBool("RCTL_RELAY_ALLOW_INSECURE", false),
		TokenTTL:           getenvDuration("RCTL_RELAY_ENROLL_TTL", 30*time.Minute),
		ReadLimitBytes:     getenvInt64("RCTL_RELAY_READ_LIMIT", 8<<20),
		HeartbeatEvery:     getenvDuration("RCTL_RELAY_HEARTBEAT", 25*time.Second),
		WriteTimeout:       getenvDuration("RCTL_RELAY_WRITE_TIMEOUT", 10*time.Second),
		SessionLifetime:    getenvDuration("RCTL_RELAY_SESSION_LIFETIME", 30*24*time.Hour),
		TunnelTimeout:      getenvDuration("RCTL_RELAY_TUNNEL_TIMEOUT", 20*time.Second),
		TunnelMaxBody:      getenvInt64("RCTL_RELAY_TUNNEL_MAX_BODY", 2<<20),
		StreamStartTimeout: getenvDuration("RCTL_RELAY_STREAM_START_TIMEOUT", 20*time.Second),
		LoginLimit:         loadRateLimit("RCTL_RELAY_LOGIN", 5, time.Minute),
		AdminLimit:         loadRateLimit("RCTL_RELAY_ADMIN", 60, time.Minute),
		DeviceLimit:        loadRateLimit("RCTL_RELAY_DEVICE", 20, time.Minute),
		TunnelLimit:        loadRateLimit("RCTL_RELAY_TUNNEL", 240, time.Minute),
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
