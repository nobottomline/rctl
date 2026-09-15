package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"time"

	setup "github.com/nobottomline/rctl/relay/internal/setup"
)

func onlyDockerFailures(report setup.Report) bool {
	found := false
	for _, check := range report.Checks {
		if check.Severity != setup.Fail {
			continue
		}
		switch check.ID {
		case "docker", "compose":
			found = true
		default:
			return false
		}
	}
	return found
}

func offerDockerDependencies(reader *bufio.Reader, output io.Writer, interactive, approved bool) error {
	manager := setup.DockerDependencies{}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	plan, err := manager.Plan(ctx)
	cancel()
	if err != nil {
		return err
	}
	fmt.Fprintf(output, "\nDocker Engine and Compose are missing. Setup can add Docker's official signed APT repository for %s/%s, install the packages, and enable the Docker service.\n", plan.Distro, plan.Suite)
	fmt.Fprintln(output, styled(output, "These system dependencies remain installed if relay setup fails or is removed. Existing runtimes are never replaced. Docker-published ports may bypass UFW rules; check the provider firewall.", ansiYellow))
	if !approved {
		if !interactive {
			return fmt.Errorf("rerun with --yes --install-dependencies to explicitly authorize Docker installation")
		}
		confirmed, err := confirmAction(reader, output, "yes", "no")
		if err != nil {
			return err
		}
		if !confirmed {
			return fmt.Errorf("Docker installation declined; the host was not changed")
		}
	}
	installCtx, stop := lifecycleContext(15 * time.Minute)
	defer stop()
	progress := newCLIProgress(output)
	err = manager.Install(installCtx, plan, progress.Step)
	if err != nil {
		progress.Fail("Docker dependency installation did not complete")
		return err
	}
	progress.Success("Docker Engine and Compose are ready")
	return nil
}
