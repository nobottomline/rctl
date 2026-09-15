//go:build linux

package setup

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

type peerKey struct{}

func hostUpdatePeerContext(ctx context.Context, c net.Conn) context.Context {
	allowed := false
	if conn, ok := c.(*net.UnixConn); ok {
		raw, err := conn.SyscallConn()
		if err == nil {
			_ = raw.Control(func(fd uintptr) {
				cred, e := unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
				allowed = e == nil && (cred.Uid == 0 || cred.Uid == relayRuntimeUID)
			})
		}
	}
	return context.WithValue(ctx, peerKey{}, allowed)
}

func hostUpdatePeerHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if allowed, _ := r.Context().Value(peerKey{}).(bool); !allowed {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func ServeHostUpdates(ctx context.Context, version string) error {
	if os.Geteuid() != 0 {
		return errors.New("host update supervisor must run as root")
	}
	// Only one supervisor may own jobs and replace the socket.
	if err := os.MkdirAll(HostAgentState, 0o700); err != nil {
		return err
	}
	release, err := acquireLifecycleLock(HostAgentState + "/agent.lock")
	if err != nil {
		return err
	}
	defer release()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	u, err := NewHostUpdater(DefaultPaths(), HostAgentState, version)
	if err != nil {
		return err
	}
	if err := u.Start(ctx); err != nil {
		return err
	}
	defer func() { cancel(); u.Wait() }()
	if err := os.MkdirAll(HostAgentSocketDir, 0o755); err != nil {
		return err
	}
	if info, err := os.Lstat(HostAgentSocket); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return errors.New("unexpected file at updater socket")
		}
		if err := os.Remove(HostAgentSocket); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	listener, err := net.Listen("unix", HostAgentSocket)
	if err != nil {
		return err
	}
	defer listener.Close()
	if err := os.Chown(HostAgentSocket, 0, relayRuntimeGID); err != nil {
		return err
	}
	if err := os.Chmod(HostAgentSocket, 0o660); err != nil {
		return err
	}
	handler := hostUpdateAuthorization(u.Handler(), func() (string, error) {
		secrets, err := readExistingSecrets(DefaultPaths().RelayEnv)
		return secrets.Admin, err
	})
	server := &http.Server{
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 4096,
		ConnContext: hostUpdatePeerContext,
		Handler:     hostUpdatePeerHandler(handler),
	}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	select {
	case <-ctx.Done():
	case <-u.Restart():
	case err := <-done:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	shutdown, stop := context.WithTimeout(context.Background(), 10*time.Second)
	defer stop()
	return server.Shutdown(shutdown)
}
