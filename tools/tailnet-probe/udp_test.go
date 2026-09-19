package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"net"
	"testing"
	"time"

	"github.com/pion/turn/v5"
)

// Qualify the library boundary before exposing any bridge on a tailnet.
// The TURN listener and native peer use separate packet connections, as they
// would when replacing the listener with tsnet.ListenPacket. This is not a
// test of Tailscale routing, browser ICE, or libjuice on a physical device.
func TestTURNPacketConnBoundary(t *testing.T) {
	listen := func() net.PacketConn {
		t.Helper()
		conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = conn.Close() })
		return conn
	}
	transport, peer := listen(), listen()
	var secret [32]byte
	if _, err := rand.Read(secret[:]); err != nil {
		t.Fatal(err)
	}
	password := hex.EncodeToString(secret[:])
	const realm, username = "rctl-probe", "single-test"
	server, err := turn.NewServer(turn.ServerConfig{
		Realm: realm,
		AuthHandler: func(a *turn.RequestAttributes) (string, []byte, bool) {
			if a.Username != username || a.Realm != realm {
				return "", nil, false
			}
			return username, turn.GenerateAuthKey(username, realm, password), true
		},
		PacketConnConfigs: []turn.PacketConnConfig{{
			PacketConn: transport,
			RelayAddressGenerator: &turn.RelayAddressGeneratorStatic{
				RelayAddress: net.ParseIP("127.0.0.1"), Address: "127.0.0.1",
			},
			PermissionHandler: func(_ net.Addr, ip net.IP) bool { return ip.Equal(net.ParseIP("127.0.0.1")) },
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	clientFor := func(pass string) *turn.Client {
		t.Helper()
		client, err := turn.NewClient(&turn.ClientConfig{
			TURNServerAddr: transport.LocalAddr().String(), Conn: listen(),
			Username: username, Password: pass, RTO: 20 * time.Millisecond,
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(client.Close)
		if err := client.Listen(); err != nil {
			t.Fatal(err)
		}
		return client
	}
	if conn, err := clientFor("wrong-password").Allocate(); err == nil {
		_ = conn.Close()
		t.Fatal("unauthorized TURN allocation accepted")
	}
	client := clientFor(password)
	conn, err := client.Allocate()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := peer.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := client.CreatePermission(&net.UDPAddr{IP: net.ParseIP("192.0.2.1"), Port: 9999}); err == nil {
		t.Fatal("permission for non-local peer accepted")
	}
	payload := []byte("synthetic-udp-bridge-probe")
	if _, err := conn.WriteTo(payload, peer.LocalAddr()); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 1024)
	n, from, err := peer.ReadFrom(buffer)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buffer[:n], payload) {
		t.Fatal("native peer received incorrect bytes")
	}
	if _, err := peer.WriteTo(buffer[:n], from); err != nil {
		t.Fatal(err)
	}
	n, _, err = conn.ReadFrom(buffer)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buffer[:n], payload) {
		t.Fatal("TURN client received incorrect bytes")
	}
}
