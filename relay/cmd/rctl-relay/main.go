package main

import (
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/nobottomline/rctl/relay/internal/relay"
)

func main() {
	if len(os.Args) == 3 && os.Args[1] == "healthcheck" {
		if err := healthcheck(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	relay.Run()
}

func healthcheck(rawURL string) error {
	target, err := url.Parse(rawURL)
	if err != nil || target.Scheme != "http" || target.Hostname() != "127.0.0.1" || target.User != nil || target.RawQuery != "" || target.Fragment != "" {
		return errors.New("healthcheck URL must be loopback HTTP without credentials, query, or fragment")
	}
	client := &http.Client{Timeout: 4 * time.Second}
	response, err := client.Get(target.String())
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("healthcheck returned %s", response.Status)
	}
	return nil
}
