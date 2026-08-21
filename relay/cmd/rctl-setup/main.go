package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"runtime"
	"time"

	setup "github.com/nobottomline/rctl/relay/internal/setup"
)

var (
	version       = "dev"
	commit        = "unknown"
	defaultImage  = ""
	defaultCaddy  = ""
	defaultCoturn = ""
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 0 {
		usage()
		return 2
	}
	switch args[0] {
	case "version":
		fmt.Printf("rctl-setup %s (%s) %s/%s\n", version, commit, runtime.GOOS, runtime.GOARCH)
		return 0
	case "preflight":
		return runPreflight(args[1:])
	case "help", "-h", "--help":
		usage()
		return 0
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", args[0])
		usage()
		return 2
	}
}

func runPreflight(args []string) int {
	flags := flag.NewFlagSet("preflight", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	configPath := flags.String("config", "", "mode-0600 JSON configuration file")
	publicURL := flags.String("public-url", "", "public HTTPS origin (non-secret)")
	image := flags.String("image", defaultImage, "digest-pinned relay image (non-secret)")
	caddyImage := flags.String("caddy-image", defaultCaddy, "digest-pinned Caddy image (non-secret)")
	coturnImage := flags.String("coturn-image", defaultCoturn, "digest-pinned coturn image (non-secret)")
	turnExternalIP := flags.String("turn-external-ip", "", "public IPv4 used by TURN (non-secret)")
	profile := flags.String("profile", setup.ProfileContainer, "container or native")
	jsonOutput := flags.Bool("json", false, "write structured JSON")
	turn := flags.Bool("turn", true, "check TURN requirements")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "preflight does not accept positional arguments")
		return 2
	}
	cfg := setup.DefaultConfig()
	var err error
	if *configPath != "" {
		cfg, err = setup.LoadConfig(*configPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "config:", err)
			return 2
		}
	} else {
		cfg.PublicURL = *publicURL
		cfg.Profile = *profile
		cfg.RelayImage = *image
		cfg.CaddyImage = *caddyImage
		cfg.CoturnImage = *coturnImage
		cfg.TURNExternalIP = *turnExternalIP
		cfg.EnableTURN = *turn
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	report := (setup.Preflight{}).Run(ctx, cfg)
	if *jsonOutput {
		if err := report.WriteJSON(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	} else {
		report.WriteText(os.Stdout)
	}
	if report.Failed() {
		return 1
	}
	return 0
}

func usage() {
	fmt.Fprintln(os.Stderr, `Usage: rctl-setup <command> [options]

Commands:
  version      print build and platform metadata
  preflight    run read-only host and configuration checks

Mutating lifecycle commands are enabled only after transactional apply and
rollback support are present.`)
}
