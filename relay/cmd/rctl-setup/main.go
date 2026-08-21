package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"runtime"
	"strings"
	"time"

	setup "github.com/nobottomline/rctl/relay/internal/setup"
)

var (
	version       = "dev"
	commit        = "unknown"
	defaultImage  = ""
	defaultCaddy  = "docker.io/library/caddy@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648"
	defaultCoturn = "docker.io/coturn/coturn@sha256:771a95d04cb97bbc5bfc672e5fdf455591c7d2b2a15f02bb9ceda3e27561695f"
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
	case "install":
		return runInstall(args[1:], os.Stdin, os.Stdout, os.Stderr)
	case "doctor":
		return runDoctor(args[1:], os.Stdout, os.Stderr)
	case "backup":
		return runBackup(args[1:], os.Stdout, os.Stderr)
	case "restore":
		return runRestore(args[1:], os.Stdin, os.Stdout, os.Stderr)
	case "help", "-h", "--help":
		usage()
		return 0
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", args[0])
		usage()
		return 2
	}
}

func runRestore(args []string, input io.Reader, output, errorsOutput io.Writer) int {
	flags := flag.NewFlagSet("restore", flag.ContinueOnError)
	flags.SetOutput(errorsOutput)
	source := flags.String("from", "", "managed backup-* directory to restore")
	dryRun := flags.Bool("dry-run", false, "validate the backup and installed state without changing services or files")
	assumeYes := flags.Bool("yes", false, "restore without an interactive confirmation")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 || *source == "" {
		fmt.Fprintln(errorsOutput, "restore requires --from and does not accept positional arguments")
		return 2
	}
	manager := setup.RestoreManager{}
	metadata, err := manager.DryRun(*source)
	if err != nil {
		fmt.Fprintln(errorsOutput, "restore validation:", err)
		return 1
	}
	fmt.Fprintf(output, "Restore source: %s\nRelease: %s\nOrigin: %s\n", *source, metadata.Release, metadata.Config.PublicURL)
	if *dryRun {
		fmt.Fprintln(output, "Restore dry run complete. No services or files were changed.")
		return 0
	}
	if !*assumeYes {
		if input != os.Stdin || !stdinIsTerminal() {
			fmt.Fprintln(errorsOutput, "restore requires an interactive terminal or --yes")
			return 2
		}
		answer, promptErr := prompt(bufio.NewReader(input), output, "Type restore to replace the installed state", "")
		if promptErr != nil || answer != "restore" {
			fmt.Fprintln(errorsOutput, "restore cancelled; the host was not changed")
			return 1
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	rollback, err := manager.Restore(ctx, *source)
	if err != nil {
		fmt.Fprintln(errorsOutput, "restore:", err)
		if rollback != "" {
			fmt.Fprintln(errorsOutput, "Pre-restore backup:", rollback)
		}
		return 1
	}
	fmt.Fprintf(output, "Restore verified. Pre-restore backup: %s\n", rollback)
	return 0
}

func runBackup(args []string, output, errorsOutput io.Writer) int {
	flags := flag.NewFlagSet("backup", flag.ContinueOnError)
	flags.SetOutput(errorsOutput)
	dryRun := flags.Bool("dry-run", false, "validate and print snapshot sources without stopping services")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(errorsOutput, "backup does not accept positional arguments")
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	manager := setup.BackupManager{}
	if *dryRun {
		sources, err := manager.DryRun()
		if err != nil {
			fmt.Fprintln(errorsOutput, "backup dry run:", err)
			return 1
		}
		fmt.Fprintln(output, "Backup dry run complete. Snapshot sources:")
		for _, source := range sources {
			fmt.Fprintln(output, " ", source)
		}
		return 0
	}
	name, err := manager.Create(ctx)
	if err != nil {
		fmt.Fprintln(errorsOutput, "backup:", err)
		return 1
	}
	fmt.Fprintf(output, "Backup verified: %s\n", name)
	return 0
}

func runDoctor(args []string, output, errorsOutput io.Writer) int {
	flags := flag.NewFlagSet("doctor", flag.ContinueOnError)
	flags.SetOutput(errorsOutput)
	jsonOutput := flags.Bool("json", false, "write structured JSON")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(errorsOutput, "doctor does not accept positional arguments")
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	report := (setup.Doctor{}).Run(ctx)
	if *jsonOutput {
		if err := report.WriteJSON(output); err != nil {
			fmt.Fprintln(errorsOutput, err)
			return 1
		}
	} else {
		report.WriteText(output)
	}
	if report.Failed() {
		return 1
	}
	return 0
}

type configFlags struct {
	configPath    string
	publicURL     string
	relayImage    string
	caddyImage    string
	coturnImage   string
	turnIP        string
	acmeEmail     string
	turn          bool
	configuration bool
}

func addConfigFlags(flags *flag.FlagSet) *configFlags {
	values := &configFlags{}
	flags.StringVar(&values.configPath, "config", "", "mode-0600 JSON configuration file")
	flags.StringVar(&values.publicURL, "public-url", "", "public HTTPS origin (non-secret)")
	flags.StringVar(&values.relayImage, "image", defaultImage, "digest-pinned relay image (non-secret)")
	flags.StringVar(&values.caddyImage, "caddy-image", defaultCaddy, "digest-pinned Caddy image (non-secret)")
	flags.StringVar(&values.coturnImage, "coturn-image", defaultCoturn, "digest-pinned coturn image (non-secret)")
	flags.StringVar(&values.turnIP, "turn-external-ip", "", "public IPv4 used by TURN (non-secret)")
	flags.StringVar(&values.acmeEmail, "acme-email", "", "ACME account email (non-secret)")
	flags.BoolVar(&values.turn, "turn", true, "deploy the recommended TURN service")
	return values
}

func (v *configFlags) load(flags *flag.FlagSet) (setup.Config, error) {
	flags.Visit(func(item *flag.Flag) {
		switch item.Name {
		case "public-url", "image", "caddy-image", "coturn-image", "turn-external-ip", "acme-email", "turn":
			v.configuration = true
		}
	})
	if v.configPath != "" {
		if v.configuration {
			return setup.Config{}, fmt.Errorf("--config cannot be combined with individual configuration flags")
		}
		return setup.LoadConfig(v.configPath)
	}
	return setup.Config{
		Schema: setup.ConfigSchema, PublicURL: v.publicURL, Profile: setup.ProfileContainer,
		RelayImage: v.relayImage, CaddyImage: v.caddyImage, CoturnImage: v.coturnImage,
		TURNExternalIP: v.turnIP, EnableTURN: v.turn, ACMEEmail: v.acmeEmail, Release: version,
	}, nil
}

func runPreflight(args []string) int {
	flags := flag.NewFlagSet("preflight", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	configValues := addConfigFlags(flags)
	jsonOutput := flags.Bool("json", false, "write structured JSON")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "preflight does not accept positional arguments")
		return 2
	}
	cfg, err := configValues.load(flags)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		return 2
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

func runInstall(args []string, input io.Reader, output, errorsOutput io.Writer) int {
	flags := flag.NewFlagSet("install", flag.ContinueOnError)
	flags.SetOutput(errorsOutput)
	configValues := addConfigFlags(flags)
	dryRun := flags.Bool("dry-run", false, "validate and print the plan without changing the host")
	assumeYes := flags.Bool("yes", false, "apply the displayed plan without an interactive confirmation")
	publicPackage := flags.String("public-package", "", "verified public rctl .deb used for admin package generation")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(errorsOutput, "install does not accept positional arguments")
		return 2
	}
	cfg, err := configValues.load(flags)
	if err != nil {
		fmt.Fprintln(errorsOutput, "config:", err)
		return 2
	}
	if *publicPackage != "" {
		if configValues.configPath != "" && !cfg.DevicePackages {
			fmt.Fprintln(errorsOutput, "config: device_packages must be true when --public-package is supplied with --config")
			return 2
		}
		cfg.DevicePackages = true
	}
	reader := bufio.NewReader(input)
	interactive := input == os.Stdin && stdinIsTerminal()
	if configValues.configPath == "" && interactive && !*assumeYes {
		if cfg.PublicURL == "" {
			cfg.PublicURL, err = prompt(reader, output, "Public HTTPS URL", "")
			if err != nil {
				fmt.Fprintln(errorsOutput, "input:", err)
				return 2
			}
		}
		if cfg.EnableTURN && cfg.TURNExternalIP == "" {
			inferred := inferPublicIPv4(cfg.PublicURL)
			cfg.TURNExternalIP, err = prompt(reader, output, "VPS public IPv4 for TURN", inferred)
			if err != nil {
				fmt.Fprintln(errorsOutput, "input:", err)
				return 2
			}
		}
		if cfg.ACMEEmail == "" {
			cfg.ACMEEmail, err = prompt(reader, output, "ACME email (optional)", "")
			if err != nil {
				fmt.Fprintln(errorsOutput, "input:", err)
				return 2
			}
		}
	}
	if err := cfg.Validate(); err != nil {
		fmt.Fprintln(errorsOutput, "config:", err)
		return 2
	}
	if cfg.Profile != setup.ProfileContainer {
		fmt.Fprintln(errorsOutput, "install: only the container profile is currently supported")
		return 2
	}

	paths := setup.DefaultPaths()
	owned, err := setup.InstallationOwned(paths)
	if err != nil {
		fmt.Fprintln(errorsOutput, "installed state:", err)
		return 1
	}
	if !owned {
		preflightCtx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		report := (setup.Preflight{}).Run(preflightCtx, cfg)
		cancel()
		report.WriteText(output)
		if report.Failed() {
			fmt.Fprintln(errorsOutput, "preflight failed; the host was not changed")
			return 1
		}
	}
	printInstallPlan(output, cfg, owned, *dryRun)
	if !*dryRun && !*assumeYes {
		if !interactive {
			fmt.Fprintln(errorsOutput, "install requires an interactive terminal or --yes")
			return 2
		}
		answer, err := prompt(reader, output, "Type install to continue", "")
		if err != nil || answer != "install" {
			fmt.Fprintln(errorsOutput, "installation cancelled; the host was not changed")
			return 1
		}
	}
	installCtx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()
	result, err := (setup.Installer{}).Install(installCtx, cfg, setup.InstallOptions{DryRun: *dryRun, Version: version, PublicPackageSource: *publicPackage})
	if err != nil {
		fmt.Fprintln(errorsOutput, "install:", err)
		return 1
	}
	if result.DryRun {
		fmt.Fprintf(output, "Dry run complete: %d owned files would be managed.\n", len(result.Files))
		return 0
	}
	if result.Fresh {
		fmt.Fprintf(output, "\nRelay installation verified.\nAdmin URL: %s/admin/\nAdmin password (shown once): %s\n", strings.TrimSuffix(cfg.PublicURL, "/"), result.AdminSecret)
	} else {
		fmt.Fprintf(output, "Relay installation is healthy and unchanged: %s/admin/\n", strings.TrimSuffix(cfg.PublicURL, "/"))
	}
	return 0
}

func prompt(reader *bufio.Reader, output io.Writer, label, defaultValue string) (string, error) {
	if defaultValue == "" {
		fmt.Fprintf(output, "%s: ", label)
	} else {
		fmt.Fprintf(output, "%s [%s]: ", label, defaultValue)
	}
	line, err := reader.ReadString('\n')
	if err != nil && len(line) == 0 {
		return "", err
	}
	line = strings.TrimSpace(line)
	if line == "" {
		line = defaultValue
	}
	return line, nil
}

func inferPublicIPv4(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	if ip := net.ParseIP(parsed.Hostname()); ip != nil && ip.To4() != nil {
		return ip.String()
	}
	addresses, err := net.LookupIP(parsed.Hostname())
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

func stdinIsTerminal() bool {
	info, err := os.Stdin.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func printInstallPlan(w io.Writer, cfg setup.Config, owned, dryRun bool) {
	action := "fresh install"
	if owned {
		action = "verify existing installation"
	}
	if dryRun {
		action += " (dry run)"
	}
	fmt.Fprintf(w, "\nPlan: %s\nOrigin: %s\nProfile: %s\nTURN: %t\nDevice packages: %t\nRelay image: %s\n", action, cfg.PublicURL, cfg.Profile, cfg.EnableTURN, cfg.DevicePackages, cfg.RelayImage)
}

func usage() {
	fmt.Fprintln(os.Stderr, `Usage: rctl-setup <command> [options]

Commands:
  version      print build and platform metadata
  preflight    run read-only host and configuration checks
  install      preflight, confirm, apply, verify, and roll back on failure
  doctor       diagnose owned files, services, HTTPS, and WebSocket routing
  backup       stop briefly, snapshot managed state, restart, and verify
  restore      validate, restore, verify, and automatically roll back`)
}
