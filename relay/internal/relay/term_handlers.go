package relay

import (
	"context"
	"encoding/base64"
	"net/http"
	"strconv"

	"nhooyr.io/websocket"
)

type termOpenRequest struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Cols int    `json:"cols,omitempty"`
	Rows int    `json:"rows,omitempty"`
}

type termInputRequest struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Body string `json:"body,omitempty"`
}

type termTunnelEvent struct {
	Type  string `json:"type"`
	ID    string `json:"id"`
	Body  string `json:"body,omitempty"`
	Error string `json:"error,omitempty"`
}

func (s *server) handleTunnelTermWS(w http.ResponseWriter, r *http.Request) {
	deviceID := r.PathValue("id")
	dc := s.getDevice(deviceID)
	if dc == nil {
		writeErr(w, http.StatusNotFound, "device_offline")
		return
	}
	if !s.deviceApproved(r.Context(), deviceID) {
		writeErr(w, http.StatusForbidden, "device_not_approved")
		return
	}

	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: s.cfg.AllowInsecure})
	if err != nil {
		return
	}
	ws.SetReadLimit(s.cfg.ReadLimitBytes)
	defer ws.Close(websocket.StatusNormalClosure, "")

	termID := "term_" + randomHex(12)
	eventCh := make(chan termTunnelEvent, 64)
	dc.registerTerm(termID, eventCh)
	defer func() {
		dc.unregisterTerm(termID)
		cancelCtx, cancel := context.WithTimeout(context.Background(), s.cfg.WriteTimeout)
		_ = dc.writeJSON(cancelCtx, map[string]string{"type": "term_cancel", "id": termID})
		cancel()
	}()

	cols, _ := strconv.Atoi(r.URL.Query().Get("cols"))
	rows, _ := strconv.Atoi(r.URL.Query().Get("rows"))
	ctx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
	err = dc.writeJSON(ctx, termOpenRequest{Type: "term_open", ID: termID, Cols: cols, Rows: rows})
	cancel()
	if err != nil {
		return
	}

	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		for {
			msgType, payload, err := ws.Read(r.Context())
			if err != nil {
				return
			}
			if msgType != websocket.MessageBinary && msgType != websocket.MessageText {
				continue
			}
			msg := termInputRequest{
				Type: "term_input",
				ID:   termID,
				Body: base64.StdEncoding.EncodeToString(payload),
			}
			writeCtx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
			err = dc.writeJSON(writeCtx, msg)
			cancel()
			if err != nil {
				return
			}
		}
	}()

	for {
		select {
		case event, ok := <-eventCh:
			if !ok {
				return
			}
			switch event.Type {
			case "term_data":
				payload, err := base64.StdEncoding.DecodeString(event.Body)
				if err != nil {
					return
				}
				writeCtx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
				err = ws.Write(writeCtx, websocket.MessageBinary, payload)
				cancel()
				if err != nil {
					return
				}
			case "term_error":
				if event.Error != "" {
					writeCtx, cancel := context.WithTimeout(r.Context(), s.cfg.WriteTimeout)
					_ = ws.Write(writeCtx, websocket.MessageText, []byte(event.Error))
					cancel()
				}
				return
			case "term_close":
				return
			}
		case <-readDone:
			return
		case <-r.Context().Done():
			return
		}
	}
}
