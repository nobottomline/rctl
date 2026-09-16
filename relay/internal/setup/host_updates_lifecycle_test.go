package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nobottomline/rctl/relay/internal/releasefeed"
)

func TestHostServiceKeepsContainerSocketDirectory(t *testing.T) {
	// A relay bind mount retains the old directory inode if systemd removes and
	// recreates RuntimeDirectory. Preserve it even for separate stop/start calls.
	if !strings.Contains(hostAgentUnit, "\nRuntimeDirectoryPreserve=yes\n") {
		t.Fatal("service stop must not remove the Docker-bound socket directory")
	}
}

func TestHostUpdaterRestartReverifiesRecentCatalog(t *testing.T) {
	for _, phase := range []string{"idle", "checking", "succeeded"} {
		t.Run(phase, func(t *testing.T) {
			old, catalog := updateFixture(t)
			old.state.Status.Phase = phase
			old.state.Status.CheckedAt = time.Now().Unix()
			old.state.Status.Latest = catalog.Version
			old.state.Highest = catalog.Version
			old.state.Status.Job = &HostUpdateJob{Target: "0.4.0", Phase: "succeeded", CompletedAt: 1}
			if err := old.persistLocked(); err != nil {
				t.Fatal(err)
			}
			u, err := NewHostUpdater(old.paths, old.stateDir, old.version)
			if err != nil {
				t.Fatal(err)
			}
			u.installed = old.installed
			checked := make(chan struct{}, 1)
			u.check = func(context.Context) (releasefeed.Catalog, error) {
				checked <- struct{}{}
				return catalog, nil
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer func() { cancel(); u.Wait() }()
			if err := u.Start(ctx); err != nil {
				t.Fatal(err)
			}
			select {
			case <-checked:
			case <-time.After(5 * time.Second):
				t.Fatal("recent timestamp suppressed startup verification")
			}
			cancel()
			u.Wait()
			s := u.Status()
			if s.Phase != "idle" || !s.Available || s.Job == nil || s.Job.Phase != "succeeded" {
				t.Fatalf("restart left stale status or lost the last job: %+v", s)
			}
		})
	}
}

func TestHostUpdaterManualCheckStillHasCooldown(t *testing.T) {
	u, catalog := updateFixture(t)
	var calls atomic.Int32
	u.check = func(context.Context) (releasefeed.Catalog, error) {
		calls.Add(1)
		return catalog, nil
	}
	checked(t, u)
	checked(t, u)
	if calls.Load() != 1 {
		t.Fatal("manual checks bypassed cooldown", calls.Load())
	}
}

func TestHostUpdaterRechecksAutomaticPolicyAtJobStart(t *testing.T) {
	for _, change := range []string{"disabled", "window_changed", "already_attempted"} {
		t.Run(change, func(t *testing.T) {
			u, _ := updateFixture(t)
			checked(t, u)
			u.state.Status.Policy = HostUpdatePolicy{Automatic: true, HourUTC: u.now().UTC().Hour()}
			selected := u.Status().Latest
			// The scheduler selected this release, but policy changed before its
			// serialized install request acquired the lock.
			switch change {
			case "disabled":
				u.state.Status.Policy.Automatic = false
			case "window_changed":
				u.state.Status.Policy.HourUTC = (u.now().UTC().Hour() + 1) % 24
			case "already_attempted":
				u.state.Attempted = selected
			}
			if u.install(selected, true) == nil || u.Status().Job != nil {
				t.Fatal("stale scheduler decision started an unauthorized job")
			}
		})
	}
}

func TestHostUpdaterCheckpointOverridesPersistedPhase(t *testing.T) {
	for _, phase := range []string{"idle", "storage_error", "check_failed"} {
		for _, fails := range []bool{false, true} {
			name := phase + "/recovered"
			if fails {
				name = phase + "/blocked"
			}
			t.Run(name, func(t *testing.T) {
				u, catalog := updateFixture(t)
				u.state.Status.Phase = phase
				if err := beginRecovery(u.paths, "backup", "", time.Now()); err != nil {
					t.Fatal(err)
				}
				stage, err := os.MkdirTemp(u.stateDir, "stage-")
				if err != nil {
					t.Fatal(err)
				}
				var recovered atomic.Bool
				u.recover = func(context.Context) error {
					recovered.Store(true)
					if fails {
						return errors.New("fixture recovery failure")
					}
					return clearRecovery(u.paths)
				}
				u.installed = func() (string, error) {
					if !recovered.Load() {
						t.Error("read installed version before recovering the checkpoint")
					}
					return "0.4.0", nil
				}
				var checks atomic.Int32
				u.check = func(context.Context) (releasefeed.Catalog, error) {
					checks.Add(1)
					return catalog, nil
				}
				ctx, cancel := context.WithCancel(context.Background())
				if err := u.Start(ctx); err != nil {
					cancel()
					t.Fatal(err)
				}
				cancel()
				u.Wait()
				if !recovered.Load() {
					t.Fatal("checkpoint ignored because job phase was stale")
				}
				_, stageErr := os.Stat(stage)
				if fails {
					if u.Status().Phase != "recovery_required" || checks.Load() != 0 || stageErr != nil {
						t.Fatal("failed recovery did not preserve evidence and block checks", u.Status(), stageErr)
					}
				} else if !errors.Is(stageErr, os.ErrNotExist) {
					t.Fatal("recovered stage was not cleaned", stageErr)
				}
			})
		}
	}
}

func TestHostUpdaterOperatorRecoveryUnblocksRestart(t *testing.T) {
	u, _ := updateFixture(t)
	u.state.Status.Phase = "recovery_required"
	u.state.Status.Job = &HostUpdateJob{Target: "0.5.0", Phase: "recovery_required"}
	// The operator completed `recover`; no lifecycle checkpoint remains.
	u.recover = func(context.Context) error { return nil }
	ctx, cancel := context.WithCancel(context.Background())
	if err := u.Start(ctx); err != nil {
		cancel()
		t.Fatal(err)
	}
	cancel()
	u.Wait()
	s := u.Status()
	if s.Phase == "recovery_required" || s.Job == nil || s.Job.Phase != "interrupted" {
		t.Fatal("operator recovery remained permanently blocked", s)
	}
	raw, err := readRegularFile(filepath.Join(u.stateDir, "state.json"), 64<<10, 0o600)
	if err != nil || strings.Contains(string(raw), `"phase":"recovery_required"`) {
		t.Fatal("recovered state was not persisted", err)
	}
}
