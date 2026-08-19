package relay

import (
	"net/http"
	"testing"
)

func TestApplyStreamMetadata(t *testing.T) {
	length := int64(70 << 20)
	header := make(http.Header)
	applyStreamMetadata(header, streamTunnelEvent{
		ContentType:        "application/octet-stream",
		ContentDisposition: `attachment; filename="video.mp4"`,
		ContentLength:      &length,
	})

	if got := header.Get("Content-Type"); got != "application/octet-stream" {
		t.Fatalf("Content-Type = %q", got)
	}
	if got := header.Get("Content-Disposition"); got != `attachment; filename="video.mp4"` {
		t.Fatalf("Content-Disposition = %q", got)
	}
	if got := header.Get("Content-Length"); got != "73400320" {
		t.Fatalf("Content-Length = %q", got)
	}
}

func TestApplyStreamMetadataRejectsHeaderInjection(t *testing.T) {
	length := int64(-1)
	header := make(http.Header)
	applyStreamMetadata(header, streamTunnelEvent{
		ContentType:        "video/mp4\r\nX-Injected: true",
		ContentDisposition: "attachment; filename=bad\nname",
		ContentLength:      &length,
	})

	if len(header) != 0 {
		t.Fatalf("unsafe metadata was accepted: %#v", header)
	}
}
