package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"syscall"
	"testing"
	"time"

	"tailscale.com/ipn/ipnlocal"
	"tailscale.com/tsweb"
)

func TestMobileCertificateBoundary(t *testing.T) {
	for _, tc := range []struct {
		method, path string
		permit       bool
		status       int
	}{
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=pair&min_validity=0s", true, 200},
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=pair", false, 403},
		{"POST", "/localapi/v0/cert/test.example.ts.net?type=pair", true, 405},
		{"GET", "/localapi/v0/cert/test.invalid?type=pair", true, 400},
		{"GET", "/localapi/v0/cert/*.example.ts.net?type=pair", true, 400},
		{"GET", "/localapi/v0/cert/Test.example.ts.net?type=pair", true, 400},
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=key", true, 400},
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=pair&type=key", true, 400},
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=pair&unknown=1", true, 400},
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=pair&min_validity=%", true, 400},
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=pair&min_validity=0s&min_validity=1s", true, 400},
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=pair&min_validity=-1s", true, 400},
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=pair&min_validity=999h", true, 400},
		{"GET", "/localapi/v0/cert/test.example.ts.net?type=pair&min_validity=bad", true, 400},
	} {
		t.Run(tc.method+tc.path, func(t *testing.T) {
			calls := 0
			w := httptest.NewRecorder()
			serveMobileCertificate(w, httptest.NewRequest(tc.method, tc.path, nil), tc.permit,
				func(ctx context.Context, domain string, validity time.Duration) (*ipnlocal.TLSCertKeyPair, error) {
					calls++
					if domain != "test.example.ts.net" || validity != 0 {
						t.Fatal("unexpected issuance request")
					}
					return &ipnlocal.TLSCertKeyPair{KeyPEM: []byte("synthetic-key\n"), CertPEM: []byte("synthetic-cert\n")}, nil
				})
			if w.Code != tc.status || w.Header().Get("Cache-Control") != "no-store" {
				t.Fatal(w.Code, w.Body.String())
			}
			if tc.status != 200 && calls != 0 {
				t.Fatal("denied request reached certificate backend")
			}
			if tc.status == 200 && (calls != 1 || w.Body.String() != "synthetic-key\nsynthetic-cert\n") {
				t.Fatal("invalid certificate pair response")
			}
		})
	}
}

type syntheticRateLimit struct{ retry string }

func (e syntheticRateLimit) Error() string { return "private-account-detail" }
func (e syntheticRateLimit) HTTPStatus() tsweb.HTTPError {
	return tsweb.HTTPError{Code: 429, Msg: e.Error(), Header: http.Header{"Retry-After": {e.retry}, "X-Private": {"private-account-detail"}}}
}

func TestMobileCertificateRateLimit(t *testing.T) {
	for _, retry := range []string{"120", "-1", "invalid-private-value", "4294967296"} {
		w := httptest.NewRecorder()
		serveMobileCertificate(w, httptest.NewRequest("GET", "/localapi/v0/cert/test.example.ts.net?type=pair", nil), true,
			func(context.Context, string, time.Duration) (*ipnlocal.TLSCertKeyPair, error) {
				return nil, fmt.Errorf("wrapped: %w", syntheticRateLimit{retry})
			})
		wantRetry := ""
		if retry == "120" {
			wantRetry = retry
		}
		if w.Code != 429 || w.Header().Get("Retry-After") != wantRetry || w.Header().Get("X-Private") != "" || strings.Contains(w.Body.String(), "private") || !strings.Contains(w.Body.String(), "rate-limit") {
			t.Fatal("unsafe or lost rate-limit response", w)
		}
	}
}

func TestMobileCertificateRedaction(t *testing.T) {
	w := httptest.NewRecorder()
	serveMobileCertificate(w, httptest.NewRequest("GET", "/localapi/v0/cert/test.example.ts.net?type=pair", nil), true,
		func(context.Context, string, time.Duration) (*ipnlocal.TLSCertKeyPair, error) {
			return nil, errors.New("private-account-detail")
		})
	if w.Code != 503 || strings.Contains(w.Body.String(), "private-account-detail") {
		t.Fatal("upstream error was exposed")
	}
}

func TestCertificateFailureRedaction(t *testing.T) {
	for _, input := range []string{"acme.Register: private-account-detail", "SetDNS private-challenge-token", "arbitrary private detail", "Certificate acquisition failed: timeout"} {
		category := certificateFailure(errors.New(input))
		if strings.Contains(category, "private") || strings.Contains(category, "token") || category == input {
			t.Fatal("unredacted certificate failure")
		}
	}
	if got := certificateFailure(fmt.Errorf("SetDNS private-challenge-token: %w", syscall.ETIMEDOUT)); got != "timeout" {
		t.Fatal("socket timeout not classified", got)
	}
	for _, category := range []string{"timeout", "challenge-setdns", "rate-limit", "dns-challenge-http-403"} {
		if got := certificateFailure(fmt.Errorf("503 Service Unavailable: Certificate acquisition failed: %s\n", category)); got != category {
			t.Fatal("safe category lost across LocalAPI", got)
		}
	}
}

func TestCertificateReadiness(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	for _, tc := range []struct {
		name        string
		from, until time.Time
		ok          bool
	}{
		{"test.example.ts.net", time.Now().Add(-time.Hour), time.Now().Add(time.Hour), true},
		{"other.example.ts.net", time.Now().Add(-time.Hour), time.Now().Add(time.Hour), false},
		{"test.example.ts.net", time.Now().Add(-2 * time.Hour), time.Now().Add(-time.Hour), false},
		{"test.example.ts.net", time.Now().Add(time.Hour), time.Now().Add(2 * time.Hour), false},
	} {
		leaf := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"test.example.ts.net"}, NotBefore: tc.from, NotAfter: tc.until}
		der, err := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
		if err != nil {
			t.Fatal(err)
		}
		certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		if err := validateCertificate(tc.name, certPEM, keyPEM); (err == nil) != tc.ok {
			t.Fatal("incorrect certificate readiness", err)
		}
	}
	if validateCertificate("test.example.ts.net", []byte("invalid"), keyPEM) == nil {
		t.Fatal("invalid certificate accepted")
	}
}
