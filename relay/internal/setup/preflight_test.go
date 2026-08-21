package setup

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"
)

type fakeProber struct {
	platform Platform
	dns      []net.IP
	dnsErr   error
	commands map[string]string
	ports    map[string]error
	paths    map[string]bool
}

func (f fakeProber) Platform(string) (Platform, error) { return f.platform, nil }
func (f fakeProber) LookupIP(context.Context, string) ([]net.IP, error) {
	return f.dns, f.dnsErr
}
func (f fakeProber) Command(_ context.Context, name string, args ...string) (string, error) {
	key := name + " " + strings.Join(args, " ")
	if value, ok := f.commands[key]; ok {
		return value, nil
	}
	return "", errors.New("command unavailable")
}
func (f fakeProber) TCPPortAvailable(port int) error      { return f.ports["tcp"] }
func (f fakeProber) UDPPortAvailable(port int) error      { return f.ports["udp"] }
func (f fakeProber) PathExists(path string) (bool, error) { return f.paths[path], nil }

func passingProbe() fakeProber {
	return fakeProber{
		platform: Platform{OS: "linux", Arch: "amd64", Distro: "ubuntu", Root: true, Memory: 2 << 30, Disk: 20 << 30},
		dns:      []net.IP{net.ParseIP("8.8.8.8")},
		commands: map[string]string{
			"docker version --format {{.Server.Version}}":                                       "27.1.0",
			"docker compose version --short":                                                    "2.29.0",
			"docker ps --all --filter label=com.docker.compose.project=rctl --format {{.ID}}":   "",
			"docker network ls --filter label=com.docker.compose.project=rctl --format {{.ID}}": "",
			"timedatectl show --property=NTPSynchronized --value":                               "yes",
		},
		ports: map[string]error{},
		paths: map[string]bool{},
	}
}

func TestPreflightRejectsUnownedComposeRuntime(t *testing.T) {
	probe := passingProbe()
	probe.commands["docker ps --all --filter label=com.docker.compose.project=rctl --format {{.ID}}"] = "deadbeef"
	report := (Preflight{Probe: probe}).Run(context.Background(), validConfig())
	for _, check := range report.Checks {
		if check.ID == "existing_containers" && check.Severity == Fail {
			return
		}
	}
	t.Fatalf("missing existing container failure: %#v", report.Checks)
}

func TestPreflightRejectsDNSPointingAwayFromTURNAddress(t *testing.T) {
	probe := passingProbe()
	probe.dns = []net.IP{net.ParseIP("1.1.1.1")}
	report := (Preflight{Probe: probe}).Run(context.Background(), validConfig())
	for _, check := range report.Checks {
		if check.ID == "dns_target" && check.Severity == Fail {
			return
		}
	}
	t.Fatalf("missing DNS target failure: %#v", report.Checks)
}

func TestPreflightPassesHealthyHost(t *testing.T) {
	report := (Preflight{Probe: passingProbe()}).Run(context.Background(), validConfig())
	if report.Failed() {
		t.Fatalf("unexpected failure: %#v", report.Checks)
	}
	foundBoundary := false
	for _, check := range report.Checks {
		if check.ID == "public_firewall" && check.Severity == Warn && strings.Contains(check.Detail, "UDP 49160-49260") {
			foundBoundary = true
		}
	}
	if !foundBoundary {
		t.Fatalf("missing cloud firewall boundary warning: %#v", report.Checks)
	}
}

func TestPreflightReportsAllIndependentFailures(t *testing.T) {
	probe := passingProbe()
	probe.platform.Root = false
	probe.platform.Memory = 128 << 20
	probe.platform.Disk = 100 << 20
	probe.dns = nil
	probe.dnsErr = errors.New("NXDOMAIN")
	probe.commands = map[string]string{}
	probe.ports["tcp"] = errors.New("address in use")
	report := (Preflight{Probe: probe}).Run(context.Background(), validConfig())
	if !report.Failed() {
		t.Fatal("expected preflight failure")
	}
	wanted := map[string]bool{"privileges": false, "memory": false, "disk": false, "dns": false, "docker": false, "compose": false, "http_port": false}
	for _, check := range report.Checks {
		if check.Severity == Fail {
			if _, ok := wanted[check.ID]; ok {
				wanted[check.ID] = true
			}
		}
	}
	for id, seen := range wanted {
		if !seen {
			t.Errorf("missing failed check %q: %#v", id, report.Checks)
		}
	}
}
