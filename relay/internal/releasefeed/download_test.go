package releasefeed

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestDownloadVerifiesExactArtifactBeforeActivation(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		status     int
		valid      bool
	}{
		{"valid", "candidate", 200, true}, {"truncated", "candidat", 200, false}, {"corrupt", "candidatx", 200, false},
		{"oversized", "candidate-extra", 200, false}, {"missing", "candidate", 404, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := fixture(time.Now())
			name := Names(c.Version)[0]
			a, _ := Inspect(strings.NewReader("candidate"))
			c.Artifacts[name] = a
			client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.String() != c.AssetURL(name) {
					t.Fatal(r.URL)
				}
				return &http.Response{StatusCode: tc.status, Body: io.NopCloser(strings.NewReader(tc.body)), Header: make(http.Header)}, nil
			})}
			dst := filepath.Join(t.TempDir(), "candidate")
			err := Download(context.Background(), client, c, name, dst)
			if (err == nil) != tc.valid {
				t.Fatal(err)
			}
			if !tc.valid {
				if _, err := os.Stat(dst); !os.IsNotExist(err) {
					t.Fatal("invalid artifact retained")
				}
			} else {
				raw, _ := os.ReadFile(dst)
				if !bytes.Equal(raw, []byte("candidate")) {
					t.Fatal(string(raw))
				}
			}
		})
	}
}

func TestReleaseSourceAndRedirectRestrictions(t *testing.T) {
	for _, s := range []string{"http://github.com/file", "https://localhost/file", "https://github.com:443/file", "https://user@github.com/file", "https://example.com/file"} {
		u, _ := url.Parse(s)
		if allowedURL(u) {
			t.Fatal(s)
		}
	}
	for _, s := range []string{StableURL, Repository + "/releases/download/v0.5.0/rctl-host-stable.json"} {
		if !ValidCatalogURL(s) {
			t.Fatal(s)
		}
	}
	for _, s := range []string{Repository + "/releases/download/v../rctl-host-stable.json", Repository + "/releases/download/v0.5.0/evil.sh", StableURL + "?token=secret", "https://example.com/catalog"} {
		if ValidCatalogURL(s) {
			t.Fatal(s)
		}
	}
}
