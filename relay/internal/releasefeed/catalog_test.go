package releasefeed

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func fixture(now time.Time) Catalog {
	c := Catalog{Purpose: Purpose, Channel: "stable", Version: "0.5.0", IssuedAt: now.Unix(), ExpiresAt: now.Add(time.Hour).Unix(), AgentProtocol: 1, Artifacts: map[string]Artifact{}}
	for _, name := range Names(c.Version) {
		c.Artifacts[name] = Artifact{SHA256: strings.Repeat("a", 64), Size: 42}
	}
	return c
}

func TestSignedCatalog(t *testing.T) {
	now := time.Now()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	c := fixture(now)
	raw, err := Sign(c, key, now)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := Decode(raw, &key.PublicKey, now)
	if err != nil || decoded.Version != c.Version {
		t.Fatal(decoded, err)
	}
	other, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if _, err := Decode(raw, &other.PublicKey, now); err == nil {
		t.Fatal("accepted wrong signature")
	}
	if _, err := Decode(raw, &key.PublicKey, now.Add(2*time.Hour)); err == nil {
		t.Fatal("accepted expired catalog")
	}
	if _, err := Decode(append(raw, []byte(" {}")...), &key.PublicKey, now); err == nil {
		t.Fatal("accepted trailing JSON")
	}
	var e envelope
	_ = json.Unmarshal(raw, &e)
	e.Payload = base64.StdEncoding.EncodeToString([]byte(`{"purpose":"device-update"}`))
	tampered, _ := json.Marshal(e)
	if _, err := Decode(tampered, &key.PublicKey, now); err == nil {
		t.Fatal("accepted changed payload")
	}
}

func TestCatalogBoundaries(t *testing.T) {
	now := time.Now()
	for _, mutate := range []func(*Catalog){
		func(c *Catalog) { c.Purpose = "device-update" }, func(c *Catalog) { c.Channel = "beta" }, func(c *Catalog) { c.AgentProtocol++ },
		func(c *Catalog) { c.Version = "../0.5.0" }, func(c *Catalog) { c.IssuedAt = now.Add(time.Hour).Unix() },
		func(c *Catalog) { c.ExpiresAt = now.Add(367 * 24 * time.Hour).Unix() },
		func(c *Catalog) { delete(c.Artifacts, Names(c.Version)[0]) },
		func(c *Catalog) {
			c.Artifacts[Names(c.Version)[0]] = Artifact{SHA256: strings.Repeat("a", 64), Size: MaxArtifact + 1}
		},
	} {
		c := fixture(now)
		mutate(&c)
		if c.Validate(now) == nil {
			t.Fatal("accepted invalid catalog", c)
		}
	}
}

func TestCompare(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want int
	}{{"0.10.0", "0.9.9", 1}, {"1.0.0", "1.0.0", 0}, {"0.4.1", "0.4.2", -1}} {
		got, err := Compare(tc.a, tc.b)
		if err != nil || got != tc.want {
			t.Fatal(tc, got, err)
		}
	}
	for _, bad := range []string{"dev", "1.2.3-beta", "01.2.3", "+1.2.3", "1.2.18446744073709551615"} {
		if _, err := Compare(bad, "1.2.3"); err == nil {
			t.Fatal(bad)
		}
	}
}

func TestPublicPinMatchesPackage(t *testing.T) {
	raw, err := os.ReadFile("../../../layout/usr/local/share/rctl/update-public-key.pem")
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(raw)) != strings.TrimSpace(PublicKeyPEM) {
		t.Fatal("host and device signing pins differ")
	}
}
