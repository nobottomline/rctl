package main

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	setup "github.com/nobottomline/rctl/relay/internal/setup"
)

func TestOriginPromptRetriesEmptyAndInvalidInput(t *testing.T) {
	var output strings.Builder
	got, err := promptOrigin(bufio.NewReader(strings.NewReader("\nhttp://example.com\n127.0.0.1\nrelay.example.com\n")), &output)
	if err != nil || got != "https://relay.example.com" {
		t.Fatalf("got %q: %v", got, err)
	}
	if strings.Count(output.String(), "This field is required") != 3 {
		t.Fatalf("output: %s", output.String())
	}
}

func TestOriginPromptEOFDoesNotLoop(t *testing.T) {
	_, err := promptOrigin(bufio.NewReader(strings.NewReader("\n")), io.Discard)
	if !errors.Is(err, io.EOF) {
		t.Fatalf("got %v", err)
	}
}

func TestIPv4SuggestionUsesBoundedContextAndIPv4Only(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	got := lookupPublicIPv4(ctx, "https://relay.example.com", func(ctx context.Context, network, host string) ([]net.IP, error) {
		if network != "ip4" || host != "relay.example.com" {
			t.Fatalf("%s %s", network, host)
		}
		<-ctx.Done()
		return nil, ctx.Err()
	})
	if got != "" {
		t.Fatalf("timeout produced %q", got)
	}
	got = lookupPublicIPv4(context.Background(), "https://relay.example.com", func(context.Context, string, string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("10.0.0.1"), net.ParseIP("2001:db8::1"), net.ParseIP("8.8.8.8")}, nil
	})
	if got != "8.8.8.8" {
		t.Fatalf("got %q", got)
	}
}

func TestDependencyOfferRequiresOnlyDockerFailures(t *testing.T) {
	r := setup.Report{Checks: []setup.Check{{ID: "docker", Severity: setup.Fail}}}
	if !onlyDockerFailures(r) {
		t.Fatal("missing Docker should permit offering dependencies")
	}
	r.Checks = append(r.Checks, setup.Check{ID: "dns", Severity: setup.Fail})
	if onlyDockerFailures(r) {
		t.Fatal("must not install dependencies before independent blockers are resolved")
	}
	if onlyDockerFailures(setup.Report{}) {
		t.Fatal("healthy host must not install dependencies")
	}
	if onlyDockerFailures(setup.Report{Checks: []setup.Check{{ID: "existing_containers", Severity: setup.Fail}}}) {
		t.Fatal("existing unowned containers are not a missing dependency")
	}
}
