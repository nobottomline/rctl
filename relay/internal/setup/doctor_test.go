package setup

import (
	"context"
	"testing"
	"time"
)

type fakeRouteVerifier struct{ err error }

func (v fakeRouteVerifier) VerifyRoutes(context.Context, Config) error { return v.err }

func TestDoctorChecksOwnedDeploymentWithoutMutatingIt(t *testing.T) {
	runner := &fakeRunner{}
	installer := testInstaller(t, runner, &fakeVerifier{})
	if _, err := installer.Install(context.Background(), validConfig(), InstallOptions{Version: "1.2.3"}); err != nil {
		t.Fatal(err)
	}
	doctorRunner := &fakeRunner{}
	report := (Doctor{Paths: installer.Paths, Runner: doctorRunner, Verifier: fakeRouteVerifier{}}).Run(context.Background())
	if report.Failed() {
		t.Fatalf("doctor unexpectedly failed: %#v", report.Checks)
	}
	if len(doctorRunner.calls) != 3 {
		t.Fatalf("unexpected doctor commands: %#v", doctorRunner.calls)
	}
}

func TestDoctorStopsOnInvalidOwnership(t *testing.T) {
	paths := PathsUnder(t.TempDir())
	report := (Doctor{Paths: paths, Runner: &fakeRunner{}, Verifier: fakeRouteVerifier{}}).Run(context.Background())
	if !report.Failed() || len(report.Checks) != 2 || report.Checks[0].ID != "recovery" || report.Checks[1].ID != "ownership" {
		t.Fatalf("unexpected report: %#v", report.Checks)
	}
}

func TestDoctorReportsPendingRecovery(t *testing.T) {
	paths := PathsUnder(t.TempDir())
	if err := beginRecovery(paths, "backup", "", time.Unix(1700010400, 0)); err != nil {
		t.Fatal(err)
	}
	report := (Doctor{Paths: paths, Runner: &fakeRunner{}, Verifier: fakeRouteVerifier{}}).Run(context.Background())
	if !report.Failed() || len(report.Checks) == 0 || report.Checks[0].ID != "recovery" || report.Checks[0].Severity != Fail {
		t.Fatalf("unexpected report: %#v", report.Checks)
	}
}
