package relay

import (
	"crypto/rand"
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

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
