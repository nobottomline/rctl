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

// argonGate caps how many memory-hard hashes run at once. Each argon2.IDKey below
// pins 64 MB and runs on every device/enrollment handshake; without a bound, a
// burst of (even wrong) tokens stacks 64 MB allocations and OOMs the relay. A small
// gate keeps peak hash memory bounded (here 2 -> ~128 MB); real device handshakes
// are rare, so legitimate logins don't meaningfully queue.
var argonGate = make(chan struct{}, 2)

func hashToken(token string) string {
	// Cheap pre-reject before the expensive hash: real tokens are short, so anything
	// empty or absurdly long is garbage that can never match a stored hash -- skip it
	// without paying the 64 MB Argon2 cost.
	if len(token) == 0 || len(token) > 256 {
		return ""
	}
	argonGate <- struct{}{}
	defer func() { <-argonGate }()
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
