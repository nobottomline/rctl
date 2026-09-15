// Package releasefeed defines the signed, purpose-bound host update contract.
package releasefeed

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	Repository    = "https://github.com/nobottomline/rctl"
	StableURL     = Repository + "/releases/latest/download/rctl-host-stable.json"
	MaxCatalog    = 64 << 10
	MaxArtifact   = 512 << 20
	AgentProtocol = 1
	Purpose       = "rctl.host-update.v1"
)

// This is the public release pin, never a signing secret. A test checks it
// against the device package pin to prevent an accidental trust-root split.
const PublicKeyPEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEeezvNv1/hjZlOv7UT4Hk3zsIFfO/
pGLMHGh5zH7FugiPxjMy3BYpc036iEoEAYv/YNgIooc4HaZlBnutLgv/HA==
-----END PUBLIC KEY-----
`

type Artifact struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type Catalog struct {
	Purpose       string              `json:"purpose"`
	Channel       string              `json:"channel"`
	Version       string              `json:"version"`
	IssuedAt      int64               `json:"issued_at"`
	ExpiresAt     int64               `json:"expires_at"`
	AgentProtocol int                 `json:"agent_protocol"`
	Artifacts     map[string]Artifact `json:"artifacts"`
}

type envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

func PublicKey() *ecdsa.PublicKey {
	block, _ := pem.Decode([]byte(PublicKeyPEM))
	key, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		panic("invalid compiled release pin")
	}
	return key.(*ecdsa.PublicKey)
}

func Names(version string) []string {
	return []string{"rctl-setup_linux_amd64", "rctl-setup_linux_arm64", "rctl_" + version + "_iphoneos-arm.deb", "rctl_" + version + "_iphoneos-arm64.deb"}
}

func (c Catalog) AssetURL(name string) string {
	return Repository + "/releases/download/v" + c.Version + "/" + name
}

// A root operator can qualify an immutable prerelease without changing the
// stable audience. The admin UI cannot change this trust/source configuration.
func ValidCatalogURL(raw string) bool {
	if raw == StableURL {
		return true
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host != "github.com" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" {
		return false
	}
	prefix := "/nobottomline/rctl/releases/download/v"
	if !strings.HasPrefix(u.Path, prefix) || !strings.HasSuffix(u.Path, "/rctl-host-stable.json") {
		return false
	}
	v := strings.TrimSuffix(strings.TrimPrefix(u.Path, prefix), "/rctl-host-stable.json")
	_, err = Compare(v, v)
	return err == nil
}

func (c Catalog) Validate(now time.Time) error {
	if c.Purpose != Purpose || c.Channel != "stable" || c.AgentProtocol != AgentProtocol {
		return errors.New("unsupported host update purpose, channel, or agent protocol")
	}
	if _, err := Compare(c.Version, c.Version); err != nil {
		return err
	}
	if c.IssuedAt <= 0 || c.IssuedAt > now.Add(5*time.Minute).Unix() || c.ExpiresAt <= now.Unix() || c.ExpiresAt <= c.IssuedAt || c.ExpiresAt-c.IssuedAt > 366*86400 {
		return errors.New("host update catalog is expired or has invalid dates")
	}
	if len(c.Artifacts) != len(Names(c.Version)) {
		return errors.New("incomplete host release")
	}
	for _, name := range Names(c.Version) {
		a, ok := c.Artifacts[name]
		if !ok || !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(a.SHA256) || a.Size <= 0 || a.Size > MaxArtifact {
			return errors.New("invalid host release artifact")
		}
	}
	return nil
}

func Decode(raw []byte, key *ecdsa.PublicKey, now time.Time) (Catalog, error) {
	var c Catalog
	var e envelope
	if len(raw) > MaxCatalog {
		return c, errors.New("host catalog exceeds size limit")
	}
	if err := strictJSON(raw, &e); err != nil {
		return c, err
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(e.Payload)
	if err != nil {
		return c, errors.New("invalid catalog payload")
	}
	sig, err := base64.StdEncoding.Strict().DecodeString(e.Signature)
	if err != nil {
		return c, errors.New("invalid catalog signature")
	}
	digest := sha256.Sum256(payload)
	if key == nil || key.Curve != elliptic.P256() || !ecdsa.VerifyASN1(key, digest[:], sig) {
		return c, errors.New("host catalog signature verification failed")
	}
	if err := strictJSON(payload, &c); err != nil {
		return c, err
	}
	return c, c.Validate(now)
}

func Sign(c Catalog, key *ecdsa.PrivateKey, now time.Time) ([]byte, error) {
	if err := c.Validate(now); err != nil {
		return nil, err
	}
	if key == nil || key.Curve != elliptic.P256() {
		return nil, errors.New("signing key must use P-256")
	}
	raw, err := json.Marshal(c)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(raw)
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		return nil, err
	}
	return json.Marshal(envelope{base64.StdEncoding.EncodeToString(raw), base64.StdEncoding.EncodeToString(sig)})
}

func strictJSON(raw []byte, dst any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(dst); err != nil {
		return err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return errors.New("trailing JSON")
	}
	return nil
}

// Compare returns the sign of a-b; only canonical stable release versions qualify.
func Compare(a, b string) (int, error) {
	parse := func(s string) ([3]uint64, error) {
		var out [3]uint64
		parts := strings.Split(s, ".")
		if len(parts) != 3 {
			return out, errors.New("expected MAJOR.MINOR.PATCH")
		}
		for i, p := range parts {
			if p == "" || len(p) > 1 && p[0] == '0' {
				return out, errors.New("noncanonical version")
			}
			for _, r := range p {
				if r < '0' || r > '9' {
					return out, errors.New("noncanonical version")
				}
			}
			n, err := strconv.ParseUint(p, 10, 63)
			if err != nil {
				return out, err
			}
			out[i] = n
		}
		return out, nil
	}
	x, err := parse(a)
	if err != nil {
		return 0, err
	}
	y, err := parse(b)
	if err != nil {
		return 0, err
	}
	for i := range x {
		if x[i] > y[i] {
			return 1, nil
		}
		if x[i] < y[i] {
			return -1, nil
		}
	}
	return 0, nil
}

func Inspect(r io.Reader) (Artifact, error) {
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(r, MaxArtifact+1))
	if err != nil {
		return Artifact{}, err
	}
	if n <= 0 || n > MaxArtifact {
		return Artifact{}, fmt.Errorf("artifact size is outside 1..%d", MaxArtifact)
	}
	return Artifact{SHA256: hex.EncodeToString(h.Sum(nil)), Size: n}, nil
}
