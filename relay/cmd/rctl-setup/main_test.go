package main

import (
	"bufio"
	"flag"
	"io"
	"strings"
	"testing"
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
