package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"syscall"
	"time"

	"tailscale.com/ipn/ipnlocal"
	"tailscale.com/tsweb"
)

type certificateGetter func(context.Context, string, time.Duration) (*ipnlocal.TLSCertKeyPair, error)

// The upstream iOS build links ACME but omits its LocalAPI cert route.
// This adapter is in-process only; no LocalAPI TCP listener is enabled.
// Issuance, domain ownership, storage and renewal remain upstream-owned.
func serveMobileCertificate(w http.ResponseWriter, r *http.Request, permitted bool, get certificateGetter) {
	w.Header().Set("Cache-Control", "no-store")
	if !permitted {
		http.Error(w, "Certificate access denied", http.StatusForbidden)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	domain, ok := strings.CutPrefix(r.URL.Path, "/localapi/v0/cert/")
	if !ok || r.URL.RawPath != "" || !validCertificateName(domain) {
		http.Error(w, "Invalid certificate name", http.StatusBadRequest)
		return
	}
	query, queryErr := url.ParseQuery(r.URL.RawQuery)
	if queryErr != nil || len(query) > 2 || len(query["type"]) != 1 || query.Get("type") != "pair" || len(query["min_validity"]) > 1 || (len(query) == 2 && !query.Has("min_validity")) {
		http.Error(w, "Unsupported certificate request", http.StatusBadRequest)
		return
	}
	validity := time.Duration(0)
	if value := query.Get("min_validity"); value != "" {
		var err error
		validity, err = time.ParseDuration(value)
		if err != nil || validity < 0 || validity > 7*24*time.Hour {
			http.Error(w, "Invalid certificate validity", http.StatusBadRequest)
			return
		}
	}
	pair, err := get(r.Context(), domain, validity)
	if err != nil || pair == nil {
		// Certificate failures may include private hostnames or account details.
		status := http.StatusServiceUnavailable
		var upstream tsweb.HTTPStatuser
		if errors.As(err, &upstream) && upstream.HTTPStatus().Code == http.StatusTooManyRequests {
			status = http.StatusTooManyRequests
			if seconds, e := strconv.ParseUint(upstream.HTTPStatus().Header.Get("Retry-After"), 10, 32); e == nil && seconds > 0 {
				w.Header().Set("Retry-After", strconv.FormatUint(seconds, 10))
			}
		}
		category := certificateFailure(err)
		if status == http.StatusTooManyRequests {
			category = "rate-limit"
		}
		http.Error(w, "Certificate acquisition failed: "+category, status)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write(pair.KeyPEM)
	_, _ = w.Write(pair.CertPEM)
}

func certificateFailure(err error) string {
	if err == nil {
		return "empty-response"
	}
	var dns *net.DNSError
	if errors.As(err, &dns) {
		return "dns"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var networkError net.Error
	if errors.As(err, &networkError) && networkError.Timeout() {
		return "timeout"
	}
	if errors.Is(err, syscall.EADDRNOTAVAIL) {
		return "source-address-unavailable"
	}
	// LocalAPI transports errors as text. Emit only predefined categories, not
	// the upstream string, which can include DNS challenge tokens and accounts.
	message := err.Error()
	if _, rest, ok := strings.Cut(message, "set-dns response: "); ok {
		if len(rest) >= 3 {
			if status, e := strconv.Atoi(rest[:3]); e == nil && status >= 400 && status <= 599 {
				return "dns-challenge-http-" + strconv.Itoa(status)
			}
		}
	}
	if _, rest, ok := strings.Cut(message, "Certificate acquisition failed: dns-challenge-http-"); ok && len(rest) >= 3 {
		if status, e := strconv.Atoi(rest[:3]); e == nil && status >= 400 && status <= 599 {
			return "dns-challenge-http-" + strconv.Itoa(status)
		}
	}
	for _, category := range []string{"dns", "timeout", "account", "challenge-setdns", "challenge-accept", "challenge-not-offered", "source-address-unavailable", "canceled", "node-not-ready", "certificate-store", "tailnet-settings", "rate-limit"} {
		if strings.Contains(message, "Certificate acquisition failed: "+category) {
			return category
		}
	}
	switch {
	case strings.Contains(message, "context canceled"):
		return "canceled"
	case strings.Contains(message, "no nodekey"), strings.Contains(message, "not connected"):
		return "node-not-ready"
	case strings.Contains(message, "deadline exceeded"), strings.Contains(message, "timeout"):
		return "timeout"
	case strings.Contains(message, "acme.Register"), strings.Contains(message, "acme.GetReg"):
		return "account"
	case strings.Contains(message, "SetDNS"):
		return "challenge-setdns"
	case strings.Contains(message, "Accept:"):
		return "challenge-accept"
	case strings.Contains(message, "challenge not offered"):
		return "challenge-not-offered"
	case strings.Contains(message, "acmeKey"), strings.Contains(message, "permission denied"):
		return "certificate-store"
	case strings.Contains(message, "does not support getting TLS certs"), strings.Contains(message, "invalid domain"):
		return "tailnet-settings"
	case strings.Contains(message, "rateLimited"), strings.Contains(message, "429"):
		return "rate-limit"
	default:
		return "upstream"
	}
}

func validCertificateName(name string) bool {
	if len(name) > 253 || !strings.HasSuffix(name, ".ts.net") {
		return false
	}
	for _, label := range strings.Split(name, ".") {
		if validateIdentity(label, "1") != nil {
			return false
		}
	}
	return true
}

func validateCertificate(name string, certPEM, keyPEM []byte) error {
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil || len(pair.Certificate) == 0 {
		return errors.New("invalid TLS certificate pair")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil || leaf.VerifyHostname(name) != nil || time.Now().Before(leaf.NotBefore) || !time.Now().Before(leaf.NotAfter) {
		return errors.New("TLS certificate does not cover this node or is not valid now")
	}
	return nil
}
