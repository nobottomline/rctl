package relay

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"

	"golang.org/x/crypto/argon2"
)

func newTokenPair(prefix string) (string, string, error) {
	idBytes := make([]byte, 12)
	secretBytes := make([]byte, 32)
	if _, err := rand.Read(idBytes); err != nil {
		return "", "", err
	}
	if _, err := rand.Read(secretBytes); err != nil {
		return "", "", err
	}
	return prefix + "_" + base64.RawURLEncoding.EncodeToString(idBytes), base64.RawURLEncoding.EncodeToString(secretBytes), nil
}

func hashToken(token string) string {
	sum := argon2.IDKey([]byte(token), []byte("rctl-relay-v1"), 1, 64*1024, 4, 32)
	return hex.EncodeToString(sum)
}

// hmacToken keys a fast HMAC-SHA256 with the server session secret. Used for
// session lookups, which run on every authenticated request: the session secret
// is already high-entropy random, so a memory-hard hash (hashToken) adds no
// security here while costing 64 MB and real CPU per request — under interactive
// load that starved the relay (OOM) and made session checks fail spuriously.
func hmacToken(key, token string) string {
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(token))
	return hex.EncodeToString(mac.Sum(nil))
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
