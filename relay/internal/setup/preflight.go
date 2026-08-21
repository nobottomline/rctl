package setup

import (
	"context"
	"fmt"
	"net"
	"sort"
	"strings"
)

const (
	minimumMemory = 512 << 20
	minimumDisk   = 2 << 30
)

type Preflight struct {
	Probe Prober
}

func (p Preflight) Run(ctx context.Context, cfg Config) Report {
	if p.Probe == nil {
		p.Probe = SystemProber{}
	}
	report := Report{}
	add := func(id string, severity Severity, summary, detail string) {
		report.Checks = append(report.Checks, Check{ID: id, Severity: severity, Summary: summary, Detail: detail})
	}

	if err := cfg.Validate(); err != nil {
		add("config", Fail, "Configuration is invalid", err.Error())
		return report
	}
	add("config", Pass, "Configuration is valid", "")

	platform, err := p.Probe.Platform("/")
	if err != nil {
		add("platform", Fail, "Host platform could not be inspected", err.Error())
	} else {
		if platform.OS != "linux" {
			add("platform", Fail, "Unsupported operating system", platform.OS)
		} else if platform.Arch != "amd64" && platform.Arch != "arm64" {
			add("platform", Fail, "Unsupported CPU architecture", platform.Arch)
		} else if platform.Distro != "debian" && platform.Distro != "ubuntu" {
			add("platform", Fail, "Unsupported Linux distribution", emptyAs(platform.Distro, "unknown"))
		} else {
			add("platform", Pass, "Supported Linux host", platform.Distro+"/"+platform.Arch)
		}
		if !platform.Root {
			add("privileges", Fail, "Root privileges are required", "run the verified setup binary through sudo")
		} else {
			add("privileges", Pass, "Running with root privileges", "")
		}
		if platform.Memory > 0 && platform.Memory < minimumMemory {
			add("memory", Fail, "Insufficient memory", formatBytes(platform.Memory)+" available; 512 MiB required")
		} else if platform.Memory > 0 && platform.Memory < 1<<30 {
			add("memory", Warn, "Memory is below the recommended 1 GiB", formatBytes(platform.Memory))
		} else {
			add("memory", Pass, "Memory capacity is sufficient", formatBytes(platform.Memory))
		}
		if platform.Disk > 0 && platform.Disk < minimumDisk {
			add("disk", Fail, "Insufficient free disk space", formatBytes(platform.Disk)+" available; 2 GiB required")
		} else {
			add("disk", Pass, "Disk capacity is sufficient", formatBytes(platform.Disk))
		}
	}

	origin, _ := ParsePublicOrigin(cfg.PublicURL)
	host := origin.Hostname()
	if ip := net.ParseIP(host); ip != nil {
		add("dns", Warn, "Bare-IP TLS profile requires separate qualification", ip.String())
		if cfg.EnableTURN && !ip.Equal(net.ParseIP(cfg.TURNExternalIP)) {
			add("dns_target", Fail, "HTTPS and TURN public addresses differ", "the dedicated single-origin profile requires the URL IP to equal turn_external_ip")
		}
	} else {
		ips, err := p.Probe.LookupIP(ctx, host)
		if err != nil || len(ips) == 0 {
			detail := "no A or AAAA answers"
			if err != nil {
				detail = err.Error()
			}
			add("dns", Fail, "Public hostname does not resolve", detail)
		} else {
			answers := uniqueIPs(ips)
			add("dns", Pass, "Public hostname resolves", strings.Join(answers, ", "))
			if cfg.EnableTURN {
				wanted := net.ParseIP(cfg.TURNExternalIP)
				matched := false
				for _, answer := range ips {
					matched = matched || answer.Equal(wanted)
				}
				if matched {
					add("dns_target", Pass, "Hostname points to the TURN public address", wanted.String())
				} else {
					add("dns_target", Fail, "Hostname does not point to this deployment address", "DNS answers do not include turn_external_ip "+wanted.String()+"; disable CDN proxying and correct the A record")
				}
			}
			for _, ip := range ips {
				if ip.To4() == nil {
					add("ipv6", Warn, "AAAA record requires working public IPv6", "a stale AAAA record can break ACME and clients")
					break
				}
			}
		}
	}

	if cfg.Profile == ProfileContainer {
		if output, err := p.Probe.Command(ctx, "docker", "version", "--format", "{{.Server.Version}}"); err != nil {
			add("docker", Fail, "Docker daemon is unavailable", commandDetail(output, err))
		} else {
			add("docker", Pass, "Docker daemon is available", output)
		}
		if output, err := p.Probe.Command(ctx, "docker", "compose", "version", "--short"); err != nil {
			add("compose", Fail, "Docker Compose v2 is unavailable", commandDetail(output, err))
		} else {
			add("compose", Pass, "Docker Compose v2 is available", output)
		}
	}

	for _, item := range []struct {
		id       string
		protocol string
		port     int
	}{
		{"http_port", "tcp", 80},
		{"https_port", "tcp", 443},
		{"turn_tcp", "tcp", 3478},
		{"turn_udp", "udp", 3478},
	} {
		if !cfg.EnableTURN && strings.HasPrefix(item.id, "turn_") {
			continue
		}
		var err error
		if item.protocol == "udp" {
			err = p.Probe.UDPPortAvailable(item.port)
		} else {
			err = p.Probe.TCPPortAvailable(item.port)
		}
		if err != nil {
			add(item.id, Fail, fmt.Sprintf("Required %s port %d is occupied", item.protocol, item.port), err.Error())
		} else {
			add(item.id, Pass, fmt.Sprintf("Required %s port %d is available", item.protocol, item.port), "")
		}
	}
	if cfg.EnableTURN {
		occupied := make([]string, 0)
		for port := 49160; port <= 49260; port++ {
			if err := p.Probe.UDPPortAvailable(port); err != nil {
				occupied = append(occupied, fmt.Sprintf("%d", port))
				if len(occupied) == 8 {
					break
				}
			}
		}
		if len(occupied) != 0 {
			add("turn_relay_ports", Fail, "TURN relay UDP range is occupied", strings.Join(occupied, ", "))
		} else {
			add("turn_relay_ports", Pass, "TURN relay UDP range is available", "49160-49260")
		}
	}

	if output, err := p.Probe.Command(ctx, "timedatectl", "show", "--property=NTPSynchronized", "--value"); err != nil {
		add("clock", Warn, "Clock synchronization could not be confirmed", commandDetail(output, err))
	} else if strings.EqualFold(strings.TrimSpace(output), "yes") {
		add("clock", Pass, "System clock is synchronized", "")
	} else {
		add("clock", Fail, "System clock is not synchronized", "TLS and signed metadata require correct time")
	}

	for _, path := range []string{"/etc/rctl", "/opt/rctl", "/var/lib/rctl"} {
		exists, err := p.Probe.PathExists(path)
		if err != nil {
			add("existing_state", Fail, "Existing state could not be inspected", path+": "+err.Error())
		} else if exists {
			add("existing_state", Warn, "Existing rctl state requires ownership reconciliation", path)
		}
	}
	return report
}

func uniqueIPs(ips []net.IP) []string {
	set := make(map[string]struct{})
	for _, ip := range ips {
		set[ip.String()] = struct{}{}
	}
	out := make([]string, 0, len(set))
	for ip := range set {
		out = append(out, ip)
	}
	sort.Strings(out)
	return out
}

func formatBytes(value uint64) string {
	if value == 0 {
		return "unknown"
	}
	const mib = 1 << 20
	const gib = 1 << 30
	if value >= gib {
		return fmt.Sprintf("%.1f GiB", float64(value)/gib)
	}
	return fmt.Sprintf("%.0f MiB", float64(value)/mib)
}

func emptyAs(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func commandDetail(output string, err error) string {
	if output != "" {
		return output
	}
	return err.Error()
}
