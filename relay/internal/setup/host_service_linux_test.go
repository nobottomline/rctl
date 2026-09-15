//go:build linux

package setup

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestHostSocketPeerProcess(t *testing.T) {
	socket := os.Getenv("RCTL_TEST_SOCKET")
	if socket == "" {
		return
	}
	client := &http.Client{Timeout: time.Second, Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}}
	resp, err := client.Get("http://updater/status")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	fmt.Println("peer-status", resp.StatusCode)
}

func TestHostSocketAuthenticatesLinuxUID(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires disposable root Linux container to exercise distinct UIDs")
	}
	dir, err := os.MkdirTemp("/tmp", "rctl-peer-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "agent.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	// Make the test socket accessible to prove the peer check, independently of
	// the production socket's additional root:65532 mode-0660 restriction.
	if err := os.Chmod(socket, 0o666); err != nil {
		t.Fatal(err)
	}
	s := &http.Server{ConnContext: hostUpdatePeerContext, Handler: hostUpdatePeerHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))}
	go func() { _ = s.Serve(listener) }()
	defer s.Close()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		uid  uint32
		code int
	}{{0, 200}, {65532, 200}, {65534, 403}} {
		cmd := exec.Command(exe, "-test.run=^TestHostSocketPeerProcess$")
		cmd.Env = append(os.Environ(), "RCTL_TEST_SOCKET="+socket)
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: tc.uid, Gid: tc.uid}}
		out, err := cmd.CombinedOutput()
		if err != nil || !strings.Contains(string(out), fmt.Sprintf("peer-status %d", tc.code)) {
			t.Fatalf("uid %d: %s %v", tc.uid, out, err)
		}
	}
}
