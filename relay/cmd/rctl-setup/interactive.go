package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"time"

	"github.com/manifoldco/promptui"
	setup "github.com/nobottomline/rctl/relay/internal/setup"
	"golang.org/x/term"
)

type promptOutput struct{ io.Writer }

func (promptOutput) Close() error { return nil }

func chooseOrigin(reader *bufio.Reader, output io.Writer) (string, error) {
	fmt.Fprintln(output, styled(output, "Looking for local domain hints (not a complete DNS inventory)...", ansiCyan))
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	hints := setup.DomainSuggestions(ctx)
	cancel()
	if len(hints) != 0 && os.Getenv("TERM") != "dumb" {
		selected, err := selectDomain(hints, os.Stdin, output)
		if err != nil {
			return "", err
		}
		if selected != "" {
			return normalizeInteractiveOrigin(selected), nil
		}
	}
	return promptOrigin(reader, output)
}

func selectDomain(hints []string, input io.ReadCloser, output io.Writer) (value string, err error) {
	if file, ok := input.(*os.File); ok {
		fd := int(file.Fd())
		state, saveErr := term.GetState(fd)
		if saveErr != nil {
			return "", saveErr
		}
		defer func() { err = errors.Join(err, term.Restore(fd, state)) }()
	}
	items := append([]string{"Enter my own domain"}, hints...)
	selector := promptui.Select{
		Label: "Relay domain (local hints; ownership is not verified)",
		Items: items, Size: 8, Stdin: input, Stdout: promptOutput{output},
		Searcher: func(query string, index int) bool {
			return index == 0 || strings.Contains(strings.ToLower(items[index]), strings.ToLower(query))
		},
	}
	if !colorEnabled(output) {
		selector.Templates = &promptui.SelectTemplates{
			Label: "{{ . }}", Active: "> {{ . }}", Inactive: "  {{ . }}",
			Selected: "{{ . }}", Help: "Arrows: navigate; /: search; Enter: select",
		}
	}
	index, value, err := selector.Run()
	if err != nil || index == 0 {
		return "", err
	}
	return value, nil
}

func promptOrigin(reader *bufio.Reader, output io.Writer) (string, error) {
	for {
		value, err := prompt(reader, output, "Relay domain or HTTPS URL", "")
		if err != nil {
			return "", err
		}
		value = normalizeInteractiveOrigin(value)
		origin, err := setup.ParsePublicOrigin(value)
		if err != nil || net.ParseIP(origin.Hostname()) != nil {
			fmt.Fprintln(output, styled(output, "Enter a DNS domain you control, such as relay.example.com. This field is required.", ansiYellow))
			continue
		}
		return value, nil
	}
}

func inferPublicIPv4(rawURL string, output io.Writer) string {
	fmt.Fprintln(output, styled(output, "Checking domain IPv4 (up to 5 seconds)...", ansiCyan))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	address := lookupPublicIPv4(ctx, rawURL, net.DefaultResolver.LookupIP)
	if address == "" {
		fmt.Fprintln(output, styled(output, "No public IPv4 could be suggested. Enter the VPS public IPv4 below.", ansiYellow))
	}
	return address
}

// Unknown input is not consent and not cancellation: let the operator correct it.
// EOF (including an unterminated answer) must never authorize a mutation.
func confirmAction(reader *bufio.Reader, output io.Writer, action, defaultValue string) (bool, error) {
	for {
		answer, err := prompt(reader, output, "Type "+action+" to continue, or cancel", defaultValue)
		if err != nil {
			return false, err
		}
		if answer == action {
			return true, nil
		}
		switch strings.ToLower(answer) {
		case "cancel", "no", "n":
			return false, nil
		}
		fmt.Fprintln(output, styled(output, "Not confirmed. Enter exactly '"+action+"', or 'cancel' to exit.", ansiYellow))
	}
}

func lookupPublicIPv4(ctx context.Context, rawURL string, lookup func(context.Context, string, string) ([]net.IP, error)) string {
	origin, err := setup.ParsePublicOrigin(rawURL)
	if err != nil {
		return ""
	}
	addresses, err := lookup(ctx, "ip4", origin.Hostname())
	if err != nil {
		return ""
	}
	for _, address := range addresses {
		if address.To4() != nil && address.IsGlobalUnicast() && !address.IsPrivate() {
			return address.String()
		}
	}
	return ""
}
