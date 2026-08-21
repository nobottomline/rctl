package relay

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestProtocolCompatibilityUsesMajorOnly(t *testing.T) {
	if !protocolCompatible(protocolMajor) {
		t.Fatal("current protocol major must be compatible")
	}
	if protocolCompatible(protocolMajor + 1) {
		t.Fatal("a different protocol major must be rejected")
	}
}

func TestCapabilitiesEndpoint(t *testing.T) {
	s := &server{}
	recorder := httptest.NewRecorder()
	s.handleCapabilities(recorder, httptest.NewRequest(http.MethodGet, "/v1/capabilities", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	body := recorder.Body.String()
	for _, want := range []string{`"component":"relay"`, `"major":1`, `"capability.negotiation"`} {
		if !strings.Contains(body, want) {
			t.Fatalf("response %q does not contain %q", body, want)
		}
	}
}

func TestCapabilitiesAdvertisesPackageGenerationOnlyWhenReady(t *testing.T) {
	s := &server{}
	recorder := httptest.NewRecorder()
	s.handleCapabilities(recorder, httptest.NewRequest(http.MethodGet, "/v1/capabilities", nil))
	if strings.Contains(recorder.Body.String(), "package.personalization") {
		t.Fatal("package capability advertised without a verified base package")
	}
	s.publicPackage = []byte{1}
	recorder = httptest.NewRecorder()
	s.handleCapabilities(recorder, httptest.NewRequest(http.MethodGet, "/v1/capabilities", nil))
	if !strings.Contains(recorder.Body.String(), "package.personalization") {
		t.Fatal("package capability missing when a base package is ready")
	}
}
