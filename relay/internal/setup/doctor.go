package setup

import (
	"context"
	"errors"
	"fmt"
	"os"
)

type Doctor struct {
	Paths    Paths
	Runner   Runner
	Verifier RouteVerifier
}

func (d Doctor) Run(ctx context.Context) Report {
	if d.Paths.EtcDir == "" {
		d.Paths = DefaultPaths()
	}
	if d.Runner == nil {
		d.Runner = OSRunner{}
	}
	if d.Verifier == nil {
		d.Verifier = HTTPSVerifier{}
	}
	report := Report{}
	add := func(id string, severity Severity, summary, detail string) {
		report.Checks = append(report.Checks, Check{ID: id, Severity: severity, Summary: summary, Detail: detail})
	}
	if recovery, err := pendingRecovery(d.Paths); err == nil {
		add("recovery", Fail, "An interrupted lifecycle operation requires recovery", recovery.Operation+"; run rctl-setup recover")
	} else if errors.Is(err, os.ErrNotExist) {
		add("recovery", Pass, "No interrupted lifecycle operation is pending", "")
	} else {
		add("recovery", Fail, "The lifecycle recovery checkpoint is invalid", err.Error())
	}
	manifest, err := loadManifest(d.Paths.ManifestPath)
	if err != nil {
		add("ownership", Fail, "Installation ownership metadata is unavailable", err.Error())
		return report
	}
	if err := validateOwnershipManifest(manifest, d.Paths); err != nil {
		add("ownership", Fail, "Installation ownership metadata is invalid", err.Error())
		return report
	}
	add("ownership", Pass, "Installation ownership metadata is valid", "release "+manifest.Version)
	if err := verifyOwnedFiles(manifest); err != nil {
		add("files", Fail, "Managed files differ from the committed installation", err.Error())
	} else {
		add("files", Pass, "Managed files and permissions are intact", fmt.Sprintf("%d files", len(manifest.Files)))
	}
	if _, err := readExistingSecrets(d.Paths.RelayEnv); err != nil {
		add("secrets", Fail, "Relay secret storage is invalid", err.Error())
	} else {
		add("secrets", Pass, "Relay secrets are present with protected permissions", "")
	}
	composeArgs := func(extra ...string) []string {
		base := []string{"compose", "--project-name", "rctl", "--file", d.Paths.Compose}
		return append(base, extra...)
	}
	if output, err := d.Runner.Run(ctx, "docker", composeArgs("config", "--quiet")...); err != nil {
		add("compose", Fail, "Compose configuration is invalid", commandFailure(output, err))
	} else {
		add("compose", Pass, "Compose configuration is valid", "")
	}
	output, err := d.Runner.Run(ctx, "docker", composeArgs("ps", "--all", "--format", "json")...)
	if err != nil {
		add("services", Fail, "Service state could not be inspected", commandFailure(output, err))
	} else {
		states, parseErr := parseComposePS(output)
		if parseErr == nil {
			parseErr = requireHealthyServices(states, manifest.Config.EnableTURN)
		}
		if parseErr != nil {
			add("services", Fail, "Required services are not healthy", parseErr.Error())
		} else {
			add("services", Pass, "Required services are running and healthy", "")
		}
	}
	if output, err := d.Runner.Run(ctx, "docker", composeArgs("exec", "-T", "relay", "/usr/local/bin/rctl-relay", "healthcheck", "http://127.0.0.1:8080/healthz")...); err != nil {
		add("relay_local", Fail, "Relay local health check failed", commandFailure(output, err))
	} else {
		add("relay_local", Pass, "Relay local health check passed", "")
	}
	if err := d.Verifier.VerifyRoutes(ctx, manifest.Config); err != nil {
		add("public_routes", Fail, "Trusted public HTTPS/WebSocket path failed", err.Error())
	} else {
		add("public_routes", Pass, "Trusted public HTTPS and WebSocket routes are healthy", manifest.Config.PublicURL)
	}
	if manifest.Config.EnableTURN {
		add("turn_allocation", Warn, "TURN allocation requires an external network probe", "container state alone cannot prove cloud firewall and NAT reachability")
	}
	return report
}
