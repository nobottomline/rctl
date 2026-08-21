package setup

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Platform struct {
	OS     string
	Arch   string
	Distro string
	Root   bool
	Memory uint64
	Disk   uint64
}

type Prober interface {
	Platform(path string) (Platform, error)
	LookupIP(ctx context.Context, host string) ([]net.IP, error)
	Command(ctx context.Context, name string, args ...string) (string, error)
	TCPPortAvailable(port int) error
	UDPPortAvailable(port int) error
	PathExists(path string) (bool, error)
}

type SystemProber struct{}

func (SystemProber) Platform(path string) (Platform, error) {
	p := Platform{OS: runtime.GOOS, Arch: runtime.GOARCH, Root: os.Geteuid() == 0}
	raw, err := os.ReadFile("/etc/os-release")
	if err == nil {
		values := parseKeyValue(string(raw))
		p.Distro = strings.ToLower(values["ID"])
	}
	if raw, err := os.ReadFile("/proc/meminfo"); err == nil {
		scanner := bufio.NewScanner(strings.NewReader(string(raw)))
		for scanner.Scan() {
			var kb uint64
			if _, err := fmt.Sscanf(scanner.Text(), "MemTotal: %d kB", &kb); err == nil {
				p.Memory = kb * 1024
				break
			}
		}
	}
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return p, fmt.Errorf("stat filesystem: %w", err)
	}
	p.Disk = stat.Bavail * uint64(stat.Bsize)
	return p, nil
}

func (SystemProber) LookupIP(ctx context.Context, host string) ([]net.IP, error) {
	return net.DefaultResolver.LookupIP(ctx, "ip", host)
}

func (SystemProber) Command(ctx context.Context, name string, args ...string) (string, error) {
	path, err := exec.LookPath(name)
	if err != nil {
		return "", err
	}
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", "LC_ALL=C"}
	raw, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(raw)), err
}

func (SystemProber) TCPPortAvailable(port int) error {
	listener, err := net.Listen("tcp", net.JoinHostPort("", strconv.Itoa(port)))
	if err != nil {
		return err
	}
	return listener.Close()
}

func (SystemProber) UDPPortAvailable(port int) error {
	conn, err := net.ListenPacket("udp", net.JoinHostPort("", strconv.Itoa(port)))
	if err != nil {
		return err
	}
	return conn.Close()
}

func (SystemProber) PathExists(path string) (bool, error) {
	_, err := os.Lstat(path)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return false, err
}

func parseKeyValue(raw string) map[string]string {
	values := make(map[string]string)
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		value = strings.Trim(value, "\"'")
		values[key] = value
	}
	return values
}

func commandContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}
