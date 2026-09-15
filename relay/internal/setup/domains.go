package setup

import (
	"bufio"
	"context"
	"crypto/x509"
	"encoding/pem"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// DomainSuggestions are local hints, not an inventory of DNS zones or proof of
// ownership. Only the user's selected origin is subsequently checked by preflight.
func DomainSuggestions(ctx context.Context) []string {
	hostname, _ := os.Hostname()
	var hints []string
	add := func(names ...string) {
		remaining := 4096 - len(hints)
		if len(names) > remaining {
			names = names[:remaining]
		}
		hints = append(hints, names...)
	}
	add(hostname)
	if raw, err := readSmallSetupFile("/etc/hosts"); err == nil {
		scanner := bufio.NewScanner(strings.NewReader(string(raw)))
		for scanner.Scan() {
			line, _, _ := strings.Cut(scanner.Text(), "#")
			fields := strings.Fields(line)
			if len(fields) > 1 && net.ParseIP(fields[0]) != nil {
				add(fields[1:]...)
			}
		}
	}
	// Certbot's public certificate links are intentional; never read private keys.
	directory, err := os.Open("/etc/letsencrypt/live")
	if err == nil {
		entries, _ := directory.ReadDir(1024)
		directory.Close()
		for _, entry := range entries {
			if ctx.Err() != nil || len(hints) == 4096 {
				break
			}
			if !entry.IsDir() {
				continue
			}
			raw, err := readSmallSetupFile(filepath.Join("/etc/letsencrypt/live", entry.Name(), "cert.pem"))
			if err != nil {
				continue
			}
			block, _ := pem.Decode(raw)
			if block != nil && block.Type == "CERTIFICATE" {
				if certificate, err := x509.ParseCertificate(block.Bytes); err == nil {
					add(certificate.DNSNames...)
				}
			}
		}
	}
	addresses, _ := net.InterfaceAddrs()
	for i, address := range addresses {
		if i >= 16 || ctx.Err() != nil {
			break
		}
		ip, _, err := net.ParseCIDR(address.String())
		if err == nil && isPublicIP(ip) {
			if names, err := net.DefaultResolver.LookupAddr(ctx, ip.String()); err == nil {
				add(names...)
			}
		}
	}
	return normalizeDomainSuggestions(hints)
}

func readSmallSetupFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 128<<10 {
		return nil, os.ErrInvalid
	}
	return io.ReadAll(io.LimitReader(file, 128<<10))
}

func normalizeDomainSuggestions(hints []string) []string {
	seen := make(map[string]bool)
	for _, hint := range hints {
		host := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(hint), "."))
		origin, err := ParsePublicOrigin("https://" + host)
		if err != nil || origin.Hostname() != host || !strings.Contains(host, ".") || net.ParseIP(host) != nil ||
			strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".localhost") {
			continue
		}
		seen[host] = true
	}
	result := make([]string, 0, len(seen))
	for host := range seen {
		result = append(result, host)
	}
	sort.Strings(result)
	return result
}
