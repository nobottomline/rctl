package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestDomainPickerHelper(t *testing.T) {
	if os.Getenv("RCTL_TEST_DOMAIN_PICKER") != "1" {
		return
	}
	state := func() string {
		cmd := exec.Command("stty", "-a")
		cmd.Stdin = os.Stdin
		out, err := cmd.Output()
		if err != nil {
			panic(err)
		}
		// Darwin may set PENDIN when returning to canonical mode; it describes
		// pending input redisplay, not an unrestored terminal setting.
		var fields []string
		for _, field := range strings.Fields(string(out)) {
			if strings.TrimSuffix(field, ";") != "pendin" && strings.TrimSuffix(field, ";") != "-pendin" {
				fields = append(fields, field)
			}
		}
		return strings.Join(fields, " ")
	}
	before := state()
	var hints []string
	for i := 0; i < 700; i++ {
		hints = append(hints, fmt.Sprintf("site-%03d.example.com", i))
	}
	value, err := selectDomain(hints, os.Stdin, os.Stdout)
	if after := state(); before != after {
		fmt.Printf("TERMINAL_NOT_RESTORED before=%q after=%q\n", before, after)
		os.Exit(1)
	}
	if err == nil && value == "" {
		value, err = promptOrigin(bufio.NewReader(os.Stdin), os.Stdout)
	}
	fmt.Printf("\nPICKED=%s ERROR=%v\n", value, err)
	os.Exit(0)
}

func TestDomainPickerPTY(t *testing.T) {
	for _, tc := range []struct{ name, keys, want, manual string }{
		{"arrow", "\x1b[B\r", "PICKED=site-000.example.com ERROR=<nil>", ""},
		{"scroll", strings.Repeat("\x1b[B", 14) + "\r", "PICKED=site-013.example.com ERROR=<nil>", ""},
		{"search", "/site-699\x1b[B\r", "PICKED=site-699.example.com ERROR=<nil>", ""},
		{"manual", "\r", "PICKED=https://custom.example.com ERROR=<nil>", "custom.example.com\n"},
		{"cancel", "\x03", "ERROR=^C", ""},
		{"eof", "\x04", "ERROR=^D", ""},
		{"search_cancel", "/site-699\x03", "ERROR=^C", ""},
		{"search_eof", "/site-699\x04", "ERROR=^D", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmd := exec.Command(os.Args[0], "-test.run=^TestDomainPickerHelper$")
			cmd.Env = append(os.Environ(), "RCTL_TEST_DOMAIN_PICKER=1", "TERM=xterm")
			terminal, err := pty.Start(cmd)
			if err != nil {
				t.Fatal(err)
			}
			chunks := make(chan string, 256)
			go func() {
				defer close(chunks)
				buf := make([]byte, 4096)
				for {
					n, err := terminal.Read(buf)
					if n != 0 {
						chunks <- string(buf[:n])
					}
					if err != nil {
						return
					}
				}
			}()
			defer func() {
				_ = cmd.Process.Kill()
				_ = terminal.Close()
				_ = cmd.Wait()
				for range chunks {
				}
			}()
			var output strings.Builder
			deadline := time.NewTimer(10 * time.Second)
			defer deadline.Stop()
			waitFor := func(want string) {
				for !strings.Contains(output.String(), want) {
					select {
					case chunk, ok := <-chunks:
						if !ok {
							t.Fatalf("closed before %q: %s", want, output.String())
						}
						output.WriteString(chunk)
					case <-deadline.C:
						t.Fatalf("timeout before %q: %s", want, output.String())
					}
				}
			}
			waitFor("Enter my own domain")
			if _, err := terminal.Write([]byte(tc.keys)); err != nil {
				t.Fatal(err)
			}
			if tc.manual != "" {
				waitFor("Relay domain or HTTPS URL:")
				if _, err := terminal.Write([]byte(tc.manual)); err != nil {
					t.Fatal(err)
				}
			}
			waitFor(tc.want)
			if strings.Contains(output.String(), "TERMINAL_NOT_RESTORED") {
				t.Fatal(output.String())
			}
		})
	}
}
