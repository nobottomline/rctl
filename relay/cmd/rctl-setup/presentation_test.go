package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/creack/pty"
	setup "github.com/nobottomline/rctl/relay/internal/setup"
)

func TestConfirmAction(t *testing.T) {
	for _, tc := range []struct {
		name, input, action, fallback string
		want, eof, retry              bool
	}{
		{name: "exact", input: "install\n", action: "install", want: true},
		{name: "corrected", input: "yes\n\ninstal\ninstall\n", action: "install", want: true, retry: true},
		{name: "cancel", input: "cancel\n", action: "install"},
		{name: "no", input: "NO\n", action: "install"},
		{name: "eof", action: "install", eof: true},
		{name: "unterminated", input: "install", action: "install", eof: true},
		{name: "unknown then eof", input: "yes\n", action: "install", eof: true, retry: true},
		{name: "destructive exact phrase", input: "uninstall\nuninstall delete-data\n", action: "uninstall delete-data", want: true, retry: true},
		{name: "docker default declines", input: "\n", action: "yes", fallback: "no"},
		{name: "docker consent", input: "yes\n", action: "yes", fallback: "no", want: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var output strings.Builder
			got, err := confirmAction(bufio.NewReader(strings.NewReader(tc.input)), &output, tc.action, tc.fallback)
			if got != tc.want || errors.Is(err, io.EOF) != tc.eof || (err != nil && !tc.eof) {
				t.Fatalf("confirmed=%v err=%v output=%q", got, err, output.String())
			}
			if strings.Contains(output.String(), "Not confirmed.") != tc.retry {
				t.Fatalf("unexpected retry output: %q", output.String())
			}
		})
	}
}

func TestReportPlainOutputMatchesContract(t *testing.T) {
	report := setup.Report{Checks: []setup.Check{
		{Severity: setup.Pass, Summary: "Ready"},
		{Severity: setup.Warn, Summary: "Check firewall", Detail: "Check provider rules"},
		{Severity: setup.Fail, Summary: "Not ready"},
	}}
	var got, want strings.Builder
	printReport(&got, report)
	report.WriteText(&want)
	if got.String() != want.String() {
		t.Fatalf("got=%q want=%q", got.String(), want.String())
	}
}

func TestTerminalColorPolicy(t *testing.T) {
	master, terminal, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer terminal.Close()
	for _, tc := range []struct {
		name, term, noColor string
		want                bool
	}{
		{"terminal", "xterm-256color", "", true},
		{"no color", "xterm-256color", "1", false},
		{"dumb", "dumb", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("TERM", tc.term)
			t.Setenv("NO_COLOR", tc.noColor)
			if got := colorEnabled(terminal); got != tc.want {
				t.Fatalf("color=%v want=%v", got, tc.want)
			}
			if got := styled(terminal, "label", ansiCyan); strings.Contains(got, ansiCyan) != tc.want {
				t.Fatalf("incorrect styling: %q", got)
			}
			progress := newCLIProgress(terminal)
			if progress.color != tc.want {
				t.Fatal("progress color policy diverged")
			}
		})
	}
	t.Setenv("TERM", "xterm")
	t.Setenv("NO_COLOR", "")
	file, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if colorEnabled(file) || newCLIProgress(file).interactive {
		t.Fatal("character device /dev/null is not a terminal")
	}
	var output strings.Builder
	fmt.Fprint(diagnosticOutput(&output), "error")
	if output.String() != "error" || styled(&output, "plain", ansiCyan) != "plain" {
		t.Fatal("redirected output must be plain")
	}
}

func TestInstallPlanExplainsDisabledUpdates(t *testing.T) {
	var output strings.Builder
	printInstallPlan(&output, setup.Config{DeviceUpdateChannel: setup.UpdateChannelOff}, false, false)
	if !strings.Contains(output.String(), "Device updates: off") || !strings.Contains(output.String(), "enrollment and remote control remain available") {
		t.Fatal(output.String())
	}
}

func TestPresentationPTYHelper(t *testing.T) {
	if os.Getenv("RCTL_TEST_PRESENTATION") != "1" {
		return
	}
	printReport(os.Stdout, setup.Report{Checks: []setup.Check{
		{Severity: setup.Pass, Summary: "Ready"},
		{Severity: setup.Warn, Summary: "Check firewall"},
		{Severity: setup.Fail, Summary: "Not ready"},
	}})
	printInstallPlan(os.Stdout, setup.Config{DeviceUpdateChannel: setup.UpdateChannelOff}, false, false)
	fmt.Fprintln(diagnosticOutput(os.Stderr), "Diagnostic example")
	confirmed, err := confirmAction(bufio.NewReader(os.Stdin), os.Stdout, "install", "")
	fmt.Printf("CONFIRMED=%v ERROR=%v\n", confirmed, err)
	os.Exit(0)
}

func TestPresentationPTY(t *testing.T) {
	for _, tc := range []struct {
		name, term, noColor string
		color               bool
	}{
		{"color", "xterm", "", true},
		{"no-color", "xterm", "1", false},
		{"dumb", "dumb", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("TERM", tc.term)
			t.Setenv("NO_COLOR", tc.noColor)
			cmd := exec.Command(os.Args[0], "-test.run=^TestPresentationPTYHelper$")
			cmd.Env = append(os.Environ(), "RCTL_TEST_PRESENTATION=1")
			terminal, err := pty.Start(cmd)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = cmd.Process.Kill(); _ = terminal.Close(); _ = cmd.Wait() }()
			result := make(chan string, 1)
			go func() {
				data, _ := io.ReadAll(terminal)
				result <- string(data)
			}()
			if _, err := io.WriteString(terminal, "yes\ninstall\n"); err != nil {
				t.Fatal(err)
			}
			select {
			case output := <-result:
				for _, expected := range []string{"Not confirmed.", "CONFIRMED=true ERROR=<nil>", "Device update feeds are disabled"} {
					if !strings.Contains(output, expected) {
						t.Fatalf("missing %q: %q", expected, output)
					}
				}
				if strings.Contains(output, "\033[") != tc.color {
					t.Fatalf("unexpected ANSI output: %q", output)
				}
				if tc.color {
					for _, marker := range []string{ansiGreen + "[pass]", ansiYellow + "[warn]", ansiRed + "[fail]", ansiBold + "Plan", ansiCyan + "Type install", ansiRed + "Diagnostic example"} {
						if !strings.Contains(output, marker) {
							t.Fatalf("missing styled marker %q: %q", marker, output)
						}
					}
				}
			case <-time.After(10 * time.Second):
				t.Fatal("terminal confirmation timed out")
			}
		})
	}
}
