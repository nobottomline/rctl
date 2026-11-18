package relay

import (
	"testing"
	"time"
)

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

// Chunks for request ids the relay never issued (or already retired) must be
// dropped instead of growing an unbounded accumulator keyed by device-supplied
// ids.
func TestHTTPChunkForUnknownIDCreatesNoBuffer(t *testing.T) {
	dc := &deviceConn{pendingHTTP: make(map[string]chan httpTunnelResponse)}
	if !dc.handleControlMessage([]byte(`{"type":"http_response_chunk","id":"http_bogus","data":"QUJD"}`)) {
		t.Fatal("chunk was not handled")
	}
	if len(dc.pendingHTTPBuf) != 0 {
		t.Fatalf("unknown id created a buffer: %d entries", len(dc.pendingHTTPBuf))
	}

	registered := make(chan httpTunnelResponse, 1)
	dc.registerHTTP("http_known", registered)
	if !dc.handleControlMessage([]byte(`{"type":"http_response_chunk","id":"http_bogus","data":"QUJD"}`)) {
		t.Fatal("chunk was not handled")
	}
	if len(dc.pendingHTTPBuf) != 0 {
		t.Fatalf("unregistered id still created a buffer: %d entries", len(dc.pendingHTTPBuf))
	}
}

func TestChunkedHTTPResponseAssemblesBody(t *testing.T) {
	dc := &deviceConn{
		pendingHTTP:    make(map[string]chan httpTunnelResponse),
		pendingHTTPBuf: make(map[string]*httpBodyBuf),
	}
	registered := make(chan httpTunnelResponse, 1)
	dc.registerHTTP("http_1", registered)

	for _, part := range []string{"aGVsbG8", "gd29ybGQ="} { // "hello world" split
		if !dc.handleControlMessage([]byte(`{"type":"http_response_chunk","id":"http_1","data":"` + part + `"}`)) {
			t.Fatal("chunk was not handled")
		}
	}
	if !dc.handleControlMessage([]byte(`{"type":"http_response_end","id":"http_1","status":200,"content_type":"text/plain"}`)) {
		t.Fatal("response end was not handled")
	}
	// The delivered body is charged before the handler reads the channel and
	// stays charged until unregisterHTTP releases it.
	if held := dc.bodyHeld["http_1"]; held != 16 || dc.bufBytes != 16 {
		t.Fatalf("delivered body not held: %d bytes, bufBytes %d", held, dc.bufBytes)
	}
	select {
	case resp := <-registered:
		if resp.Error != "" || resp.Body != "aGVsbG8gd29ybGQ=" {
			t.Fatalf("assembled response = %q %q", resp.Error, resp.Body)
		}
	default:
		t.Fatal("response was not delivered")
	}
	dc.unregisterHTTP("http_1")
	if len(dc.pendingHTTPBuf) != 0 || dc.bufBytes != 0 {
		t.Fatalf("release leaked: %d entries, %d bytes", len(dc.pendingHTTPBuf), dc.bufBytes)
	}
}

// A delivered single response is charged like an assembled one and released
// by unregisterHTTP.
func TestSingleResponseHeldAndReleased(t *testing.T) {
	dc := &deviceConn{pendingHTTP: make(map[string]chan httpTunnelResponse)}
	registered := make(chan httpTunnelResponse, 1)
	dc.registerHTTP("http_1", registered)

	if !dc.handleControlMessage([]byte(`{"type":"http_response","id":"http_1","status":200,"body":"aGVsbG8="}`)) {
		t.Fatal("response was not handled")
	}
	if held := dc.bodyHeld["http_1"]; held != 8 || dc.bufBytes != 8 {
		t.Fatalf("single response not held: %d bytes, bufBytes %d", held, dc.bufBytes)
	}
	if _, ok := <-registered; !ok {
		t.Fatal("response was not delivered")
	}
	dc.unregisterHTTP("http_1")
	if dc.bufBytes != 0 {
		t.Fatalf("release leaked %d bytes", dc.bufBytes)
	}
}

// A response that crosses the backstop must not deliver a truncated body that
// still decodes as base64 (chunk boundaries keep the prefix valid); the
// request fails with an explicit error instead. The overflow is detected on
// the chunk that crosses the limit, not one chunk later.
func TestChunkOverflowFailsRequestClosed(t *testing.T) {
	old := maxTunnelResponseBody
	maxTunnelResponseBody = 8
	t.Cleanup(func() { maxTunnelResponseBody = old })

	dc := &deviceConn{
		pendingHTTP:    make(map[string]chan httpTunnelResponse),
		pendingHTTPBuf: make(map[string]*httpBodyBuf),
	}
	registered := make(chan httpTunnelResponse, 1)
	dc.registerHTTP("http_1", registered)

	for _, part := range []string{"YWJj", "ZGVm"} { // 4 + 4 == the cap exactly
		if !dc.handleControlMessage([]byte(`{"type":"http_response_chunk","id":"http_1","data":"` + part + `"}`)) {
			t.Fatal("chunk was not handled")
		}
	}
	if buf := dc.pendingHTTPBuf["http_1"]; buf.builder.Len() != 8 || buf.overflow {
		t.Fatalf("in-cap buffer held %d bytes, overflow=%v", buf.builder.Len(), buf.overflow)
	}
	// The next chunk crosses the cap and resets the buffer immediately.
	if !dc.handleControlMessage([]byte(`{"type":"http_response_chunk","id":"http_1","data":"Z2hp"}`)) {
		t.Fatal("chunk was not handled")
	}
	if buf := dc.pendingHTTPBuf["http_1"]; buf.builder.Len() != 0 || !buf.overflow {
		t.Fatalf("overflow buffer held %d bytes, overflow=%v", buf.builder.Len(), buf.overflow)
	}
	if !dc.handleControlMessage([]byte(`{"type":"http_response_end","id":"http_1","status":200,"content_type":"application/json"}`)) {
		t.Fatal("response end was not handled")
	}
	select {
	case resp := <-registered:
		if resp.Error != "device_response_too_large" || resp.Body != "" {
			t.Fatalf("overflow response = error %q body %q", resp.Error, resp.Body)
		}
	default:
		t.Fatal("overflow response was not delivered")
	}
	if len(dc.pendingHTTPBuf) != 0 || dc.bufBytes != 0 {
		t.Fatalf("overflowed id stayed buffered: %d entries, %d bytes", len(dc.pendingHTTPBuf), dc.bufBytes)
	}
}

// A single well-formed reply after an overflowed request must not bypass the
// overflow flag: the request still fails closed.
func TestSingleResponseAfterOverflowFailsClosed(t *testing.T) {
	old := maxTunnelResponseBody
	maxTunnelResponseBody = 4
	t.Cleanup(func() { maxTunnelResponseBody = old })

	dc := &deviceConn{
		pendingHTTP:    make(map[string]chan httpTunnelResponse),
		pendingHTTPBuf: make(map[string]*httpBodyBuf),
	}
	registered := make(chan httpTunnelResponse, 1)
	dc.registerHTTP("http_1", registered)

	if !dc.handleControlMessage([]byte(`{"type":"http_response_chunk","id":"http_1","data":"YWJjZGVm"}`)) {
		t.Fatal("chunk was not handled")
	}
	if !dc.handleControlMessage([]byte(`{"type":"http_response","id":"http_1","status":200,"body":"YQ=="}`)) {
		t.Fatal("response was not handled")
	}
	select {
	case resp := <-registered:
		if resp.Error != "device_response_too_large" || resp.Body != "" {
			t.Fatalf("overflow response = error %q body %q", resp.Error, resp.Body)
		}
	default:
		t.Fatal("overflow response was not delivered")
	}
	if len(dc.pendingHTTPBuf) != 0 || dc.bufBytes != 0 {
		t.Fatalf("buffer or budget leaked: %d entries, %d bytes", len(dc.pendingHTTPBuf), dc.bufBytes)
	}
}

// The per-connection byte budget fails closed the same way when many
// concurrent oversized responses multiply out the per-request backstop.
func TestDeviceByteBudgetFailsRequestClosed(t *testing.T) {
	oldBody, oldBudget := maxTunnelResponseBody, maxDeviceBufferedBytes
	maxTunnelResponseBody = 16
	maxDeviceBufferedBytes = 16
	t.Cleanup(func() { maxTunnelResponseBody, maxDeviceBufferedBytes = oldBody, oldBudget })

	dc := &deviceConn{
		pendingHTTP:    make(map[string]chan httpTunnelResponse),
		pendingHTTPBuf: make(map[string]*httpBodyBuf),
	}
	first := make(chan httpTunnelResponse, 1)
	second := make(chan httpTunnelResponse, 1)
	if !dc.registerHTTP("http_1", first) || !dc.registerHTTP("http_2", second) {
		t.Fatal("registrations below the budget were rejected")
	}

	if !dc.handleControlMessage([]byte(`{"type":"http_response_chunk","id":"http_1","data":"YWJjZGVmZ2hpaw=="}`)) {
		t.Fatal("chunk was not handled")
	}
	// The second request's first chunk would exceed the connection budget.
	if !dc.handleControlMessage([]byte(`{"type":"http_response_chunk","id":"http_2","data":"YWJj"}`)) {
		t.Fatal("chunk was not handled")
	}
	if buf := dc.pendingHTTPBuf["http_2"]; buf.builder.Len() != 0 || !buf.overflow {
		t.Fatalf("budget-exceeded buffer held %d bytes, overflow=%v", buf.builder.Len(), buf.overflow)
	}
	if !dc.handleControlMessage([]byte(`{"type":"http_response_end","id":"http_2","status":200}`)) {
		t.Fatal("response end was not handled")
	}
	select {
	case resp := <-second:
		if resp.Error != "device_response_too_large" {
			t.Fatalf("budget-exceeded response error = %q", resp.Error)
		}
	default:
		t.Fatal("budget-exceeded response was not delivered")
	}
	// Both charges (the first request's held accumulator and the second's
	// overflow) release to zero.
	dc.unregisterHTTP("http_1")
	dc.unregisterHTTP("http_2")
	if dc.bufBytes != 0 || len(dc.bodyHeld) != 0 {
		t.Fatalf("budget release leaked: %d bytes, %d held", dc.bufBytes, len(dc.bodyHeld))
	}
}

// Chunks that arrive after the request id was registered and retired again
// must not re-create a buffer.
func TestLateChunkAfterUnregisterCreatesNoBuffer(t *testing.T) {
	dc := &deviceConn{pendingHTTP: make(map[string]chan httpTunnelResponse)}
	registered := make(chan httpTunnelResponse, 1)
	dc.registerHTTP("http_1", registered)
	dc.unregisterHTTP("http_1")

	if !dc.handleControlMessage([]byte(`{"type":"http_response_chunk","id":"http_1","data":"QUJD"}`)) {
		t.Fatal("chunk was not handled")
	}
	if len(dc.pendingHTTPBuf) != 0 {
		t.Fatalf("retired id created a buffer: %d entries", len(dc.pendingHTTPBuf))
	}
}

// Concurrent in-flight tunnel requests on one device connection are bounded,
// so a flood of issued-but-unfinished requests cannot accumulate buffers
// without limit.
func TestRegisterHTTPRejectsBeyondConcurrencyBudget(t *testing.T) {
	old := maxPendingHTTPPerDevice
	maxPendingHTTPPerDevice = 1
	t.Cleanup(func() { maxPendingHTTPPerDevice = old })

	dc := &deviceConn{pendingHTTP: make(map[string]chan httpTunnelResponse)}
	registered := make(chan httpTunnelResponse, 1)
	if !dc.registerHTTP("http_1", registered) {
		t.Fatal("registration below the budget was rejected")
	}
	if dc.registerHTTP("http_over", make(chan httpTunnelResponse, 1)) {
		t.Fatal("registration beyond the budget was admitted")
	}
	dc.unregisterHTTP("http_1")
	if !dc.registerHTTP("http_next", make(chan httpTunnelResponse, 1)) {
		t.Fatal("registration after unregister was rejected")
	}
}

// A delivered response — even an empty or errored one — holds its slot until
// the handler finishes, so admission cannot overshoot while handlers run.
func TestDeliveredResponseHoldsAdmissionSlot(t *testing.T) {
	old := maxPendingHTTPPerDevice
	maxPendingHTTPPerDevice = 1
	t.Cleanup(func() { maxPendingHTTPPerDevice = old })

	dc := &deviceConn{pendingHTTP: make(map[string]chan httpTunnelResponse)}
	registered := make(chan httpTunnelResponse, 1)
	if !dc.registerHTTP("http_1", registered) {
		t.Fatal("registration below the budget was rejected")
	}
	if !dc.handleControlMessage([]byte(`{"type":"http_response","id":"http_1","status":500,"error":"device_error","body":"cGF5bG9hZA=="}`)) {
		t.Fatal("response was not handled")
	}
	select {
	case resp := <-registered:
		if resp.Error != "device_error" || resp.Body != "" {
			t.Fatalf("error reply kept its body: error %q body %q", resp.Error, resp.Body)
		}
	default:
		t.Fatal("response was not delivered")
	}
	if dc.registerHTTP("http_over", make(chan httpTunnelResponse, 1)) {
		t.Fatal("a delivered-but-unconsumed response released its slot early")
	}
	dc.unregisterHTTP("http_1")
	if !dc.registerHTTP("http_next", make(chan httpTunnelResponse, 1)) {
		t.Fatal("registration after unregister was rejected")
	}
}

// A terminal response whose body would exceed the connection budget fails
// closed like an oversized chunk stream does.
func TestTerminalResponseBudgetFailsClosed(t *testing.T) {
	old := maxDeviceBufferedBytes
	maxDeviceBufferedBytes = 16
	t.Cleanup(func() { maxDeviceBufferedBytes = old })

	dc := &deviceConn{
		pendingHTTP:    make(map[string]chan httpTunnelResponse),
		pendingHTTPBuf: make(map[string]*httpBodyBuf),
	}
	first := make(chan httpTunnelResponse, 1)
	second := make(chan httpTunnelResponse, 1)
	if !dc.registerHTTP("http_1", first) || !dc.registerHTTP("http_2", second) {
		t.Fatal("registrations below the budget were rejected")
	}

	if !dc.handleControlMessage([]byte(`{"type":"http_response","id":"http_1","status":200,"body":"YWJjZGVmZ2g="}`)) {
		t.Fatal("response was not handled")
	}
	select {
	case resp := <-first:
		if resp.Error != "" || resp.Body != "YWJjZGVmZ2g=" {
			t.Fatalf("in-budget response = error %q body %q", resp.Error, resp.Body)
		}
	default:
		t.Fatal("response was not delivered")
	}
	// The second terminal response would exceed the connection budget.
	if !dc.handleControlMessage([]byte(`{"type":"http_response","id":"http_2","status":200,"body":"ZWZnaGo="}`)) {
		t.Fatal("response was not handled")
	}
	select {
	case resp := <-second:
		if resp.Error != "device_response_too_large" || resp.Body != "" {
			t.Fatalf("budget-exceeded response = error %q body %q", resp.Error, resp.Body)
		}
	default:
		t.Fatal("budget-exceeded response was not delivered")
	}
	dc.unregisterHTTP("http_1")
	dc.unregisterHTTP("http_2")
	if dc.bufBytes != 0 || len(dc.bodyHeld) != 0 {
		t.Fatalf("budget release leaked: %d bytes, %d held", dc.bufBytes, len(dc.bodyHeld))
	}
}

// A device that repeats a response id must not wedge the read loop: the first
// reply is delivered, a repeat is dropped, and a waiter that misses the first
// one still fails by its own tunnel timeout.
func TestDuplicateHTTPResponseDoesNotBlockReadLoop(t *testing.T) {
	dc := &deviceConn{pendingHTTP: make(map[string]chan httpTunnelResponse)}
	registered := make(chan httpTunnelResponse, 1)
	dc.registerHTTP("http_1", registered)

	done := make(chan struct{})
	go func() {
		dc.handleControlMessage([]byte(`{"type":"http_response","id":"http_1","status":200}`))
		dc.handleControlMessage([]byte(`{"type":"http_response","id":"http_1","status":200}`))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("duplicate response blocked the device read loop")
	}
	if len(registered) != 1 {
		t.Fatalf("channel holds %d replies, want the first only", len(registered))
	}
}
