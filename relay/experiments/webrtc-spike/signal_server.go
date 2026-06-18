// Minimal 2-peer signaling relay for the WebRTC spike. Serves the browser page
// and forwards every signaling message to the OTHER connected peer. This stands
// in for the relay's /signal endpoint until Phase 2.5 wires the spike through
// the real relay.
//
//go:build ignore

package main

import (
	"context"
	"log"
	"net/http"
	"sync"

	"nhooyr.io/websocket"
)

func main() {
	var mu sync.Mutex
	peers := map[string]*websocket.Conn{} // role -> conn

	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.Dir("experiments/webrtc-spike/web")))
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		role := r.URL.Query().Get("role")
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		mu.Lock()
		peers[role] = c
		mu.Unlock()
		log.Printf("peer connected: %s", role)
		for {
			_, data, err := c.Read(r.Context())
			if err != nil {
				break
			}
			mu.Lock()
			for other, pc := range peers {
				if other != role && pc != nil {
					_ = pc.Write(context.Background(), websocket.MessageText, data)
				}
			}
			mu.Unlock()
		}
		mu.Lock()
		delete(peers, role)
		mu.Unlock()
		log.Printf("peer disconnected: %s", role)
	})

	log.Println("WebRTC spike signaling + page → http://localhost:8099")
	log.Fatal(http.ListenAndServe(":8099", mux))
}
