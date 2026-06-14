package relay

import "testing"

func TestStreamBackpressureClosesFullStreamChannel(t *testing.T) {
	dc := &deviceConn{
		pendingStream: make(map[string]chan streamTunnelEvent),
	}
	ch := make(chan streamTunnelEvent, 1)
	ch <- streamTunnelEvent{Type: "stream_chunk", ID: "stream_1", Body: "old"}
	dc.registerStream("stream_1", ch)

	if !dc.handleControlMessage([]byte(`{"type":"stream_chunk","id":"stream_1","body":"new"}`)) {
		t.Fatal("stream chunk was not handled")
	}
	if got := dc.pendingStream["stream_1"]; got != nil {
		t.Fatal("full stream channel stayed registered")
	}
	if _, ok := <-ch; !ok {
		t.Fatal("buffered stream event was unexpectedly dropped before close")
	}
	if _, ok := <-ch; ok {
		t.Fatal("full stream channel was not closed")
	}
}
