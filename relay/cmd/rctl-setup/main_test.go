package main

import (
	"bufio"
	"flag"
	"io"
	"strings"
	"testing"

	setup "github.com/nobottomline/rctl/relay/internal/setup"
)

func TestConfigFileAllowsOperationalFlags(t *testing.T) {
	flags := flag.NewFlagSet("test", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	values := addConfigFlags(flags)
	_ = flags.Bool("dry-run", false, "")
	if err := flags.Parse([]string{"--config", "/missing", "--dry-run"}); err != nil {
		t.Fatal(err)
	}
	_, err := values.load(flags)
	if err == nil || !strings.Contains(err.Error(), "stat config") {
		t.Fatalf("operational flag was incorrectly treated as configuration: %v", err)
	}
}

func TestConfigFileRejectsIndividualConfigurationFlags(t *testing.T) {
	flags := flag.NewFlagSet("test", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	values := addConfigFlags(flags)
	if err := flags.Parse([]string{"--config", "/missing", "--public-url", "https://rctl.example.com"}); err != nil {
		t.Fatal(err)
	}
	if _, err := values.load(flags); err == nil || !strings.Contains(err.Error(), "cannot be combined") {
		t.Fatalf("unexpected conflict result: %v", err)
	}
}

func TestPromptUsesDefaultAndTrimsInput(t *testing.T) {
	var output strings.Builder
	got, err := prompt(bufio.NewReader(strings.NewReader("  \n")), &output, "Value", "default")
	if err != nil || got != "default" || !strings.Contains(output.String(), "[default]") {
		t.Fatalf("got=%q output=%q err=%v", got, output.String(), err)
	}
}

func TestPublicPackageEnablesDevicePackageGeneration(t *testing.T) {
	flags := flag.NewFlagSet("test", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	values := addConfigFlags(flags)
	publicPackage := flags.String("public-package", "", "")
	if err := flags.Parse([]string{"--public-url", "https://rctl.example.test", "--public-package", "/tmp/rctl.deb"}); err != nil {
		t.Fatal(err)
	}
	cfg, err := values.load(flags)
	if err != nil {
		t.Fatal(err)
	}
	if *publicPackage == "" {
		t.Fatal("public package flag was not parsed")
	}
	cfg.DevicePackages = *publicPackage != ""
	if !cfg.DevicePackages {
		t.Fatal("device package generation was not enabled")
	}
}

func TestUpgradeAcceptsRepeatedBootstrapConfigurationFlags(t *testing.T) {
	var errorsOutput strings.Builder
	code := runUpgrade([]string{
		"--public-url", "https://rctl.example.test",
		"--turn-external-ip", "8.8.8.8",
		"--acme-email", "admin@example.test",
		"--image", "ghcr.io/example/relay@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"--caddy-image", "docker.io/library/caddy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"--coturn-image", "docker.io/coturn/coturn@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
		"--yes",
	}, strings.NewReader(""), io.Discard, &errorsOutput)
	if code == 2 || strings.Contains(errorsOutput.String(), "flag provided but not defined") {
		t.Fatalf("repeated bootstrap flags were not accepted: code=%d error=%q", code, errorsOutput.String())
	}
}

func TestConfigFlagsObserveIdentityBeforeLoad(t *testing.T) {
	flags := flag.NewFlagSet("test", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	values := addConfigFlags(flags)
	if err := flags.Parse([]string{"--public-url", "https://rctl.example.test"}); err != nil {
		t.Fatal(err)
	}
	values.observe(flags)
	if !values.configuration || !values.identityConfiguration {
		t.Fatalf("configuration=%t identity=%t", values.configuration, values.identityConfiguration)
	}
}

func TestConfigFlagsParseUpdateManifestURL(t *testing.T) {
	flags := flag.NewFlagSet("test", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	values := addConfigFlags(flags)
	manifestURL := "https://releases.example.test/rctl-update-stable.json"
	if err := flags.Parse([]string{
		"--public-url", "https://rctl.example.test",
		"--turn-external-ip", "8.8.8.8",
		"--update-manifest-url", manifestURL,
	}); err != nil {
		t.Fatal(err)
	}
	cfg, err := values.load(flags)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.UpdateManifestURL != manifestURL {
		t.Fatalf("update manifest URL=%q", cfg.UpdateManifestURL)
	}
	if cfg.DeviceUpdateChannel != setup.UpdateChannelCustom {
		t.Fatalf("update channel=%q", cfg.DeviceUpdateChannel)
	}
}

func TestConfigFlagsDefaultToStableSignedUpdates(t *testing.T) {
	flags := flag.NewFlagSet("test", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	values := addConfigFlags(flags)
	if err := flags.Parse([]string{"--public-url", "https://rctl.example.test", "--turn-external-ip", "8.8.8.8"}); err != nil {
		t.Fatal(err)
	}
	cfg, err := values.load(flags)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DeviceUpdateChannel != setup.UpdateChannelStable || cfg.UpdateManifestURL != stableUpdateManifestURL() {
		t.Fatalf("default update config=%+v", cfg)
	}
}
