package setup

import (
	"context"
	"testing"
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
	if !report.Failed() || len(report.Checks) != 1 || report.Checks[0].ID != "ownership" {
		t.Fatalf("unexpected report: %#v", report.Checks)
	}
}
