package main

import (
	"strings"
	"testing"
	"time"
)

func TestCLIProgressPlainOutputTracksStepsAndDurations(t *testing.T) {
	var output strings.Builder
	progress := newCLIProgress(&output)
	now := time.Unix(100, 0)
	progress.now = func() time.Time { return now }

	progress.Step("Checking services")
	now = now.Add(1500 * time.Millisecond)
	progress.Step("Checking HTTPS")
	now = now.Add(2 * time.Second)
	progress.Success("Deployment is healthy")

	got := output.String()
	for _, expected := range []string{
		"Progress\n",
		"[1] RUN  Checking services",
		"[1] OK  Checking services (1.5s)",
		"[2] RUN  Checking HTTPS",
		"[2] OK  Checking HTTPS (2.0s)",
		"DONE Deployment is healthy (3.5s)",
	} {
		if !strings.Contains(got, expected) {
			t.Fatalf("progress output missing %q:\n%s", expected, got)
		}
	}
	if strings.Contains(got, "\033[") {
		t.Fatalf("non-terminal output contained ANSI escapes: %q", got)
	}
}

func TestCLIProgressFailureClosesActiveStep(t *testing.T) {
	var output strings.Builder
	progress := newCLIProgress(&output)
	now := time.Unix(100, 0)
	progress.now = func() time.Time { return now }
	progress.Step("Checking HTTPS")
	now = now.Add(12 * time.Second)
	progress.Fail("Verification failed")

	got := output.String()
	if !strings.Contains(got, "[1] FAIL  Checking HTTPS (12s)") ||
		!strings.Contains(got, "ERROR Verification failed (12s)") {
		t.Fatalf("unexpected failure output:\n%s", got)
	}
}

func TestFormatDuration(t *testing.T) {
	cases := map[time.Duration]string{
		250 * time.Millisecond:  "250ms",
		1250 * time.Millisecond: "1.3s",
		12 * time.Second:        "12s",
		65 * time.Second:        "1m 5s",
		2 * time.Minute:         "2m",
	}
	for input, expected := range cases {
		if got := formatDuration(input); got != expected {
			t.Fatalf("formatDuration(%s)=%q, want %q", input, got, expected)
		}
	}
}
