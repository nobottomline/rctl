package setup

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"time"
)

const diagnosticTimeout = 15 * time.Second

type failureDiagnostics struct {
	Schema      int                   `json:"schema"`
	Stage       string                `json:"stage"`
	CapturedAt  int64                 `json:"captured_at"`
	ServiceRead string                `json:"service_read"`
	LogRead     string                `json:"caddy_log_read"`
	Services    []composeServiceState `json:"services"`
	Events      []tlsDiagnosticEvent  `json:"tls_events"`
}

type tlsDiagnosticEvent struct {
	Level   string   `json:"level"`
	Event   string   `json:"event"`
	Signals []string `json:"signals,omitempty"`
}

// Diagnostics deliberately project untrusted output onto finite vocabularies.
// Redacting known secrets from raw logs would not protect ACME account URLs,
// challenge tokens, request headers, or device identities unknown to setup.
func (i Installer) saveFailureDiagnostics(stage string) {
	info, err := os.Lstat(i.Paths.LogDir)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		i.progress("Failure diagnostics unavailable: setup journal directory is not protected")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), diagnosticTimeout)
	defer cancel()
	report := failureDiagnostics{Schema: 1, Stage: stage, CapturedAt: time.Now().Unix(), Services: []composeServiceState{}, Events: []tlsDiagnosticEvent{}}
	output, runErr := i.Runner.Run(ctx, "docker", i.composeArgs("ps", "--all", "--format", "json")...)
	report.ServiceRead = diagnosticReadStatus(ctx, runErr)
	if runErr == nil {
		states, parseErr := parseComposePS(output)
		if parseErr != nil {
			report.ServiceRead = "unrecognized_output"
		} else {
			for _, name := range []string{"relay", "caddy", "coturn"} {
				if state, ok := states[name]; ok {
					report.Services = append(report.Services, composeServiceState{
						Service: name,
						State:   diagnosticEnum(state.State, "running", "created", "restarting", "removing", "paused", "exited", "dead"),
						Health:  diagnosticEnum(state.Health, "", "starting", "healthy", "unhealthy"),
					})
				}
			}
		}
	}
	output, runErr = i.Runner.Run(ctx, "docker", i.composeArgs("logs", "--no-color", "--no-log-prefix", "--tail", "200", "caddy")...)
	report.LogRead = diagnosticReadStatus(ctx, runErr)
	if runErr == nil {
		report.Events = summarizeTLSLogs(output)
		if len(report.Events) == 0 {
			report.LogRead = "no_recognized_tls_events"
		}
	}
	name, err := writeFailureDiagnostics(i.Paths.LogDir, report)
	if err != nil {
		i.progress("Could not save failure diagnostics; lifecycle recovery will continue")
		return
	}
	i.progress("Failure diagnostics saved to " + name)
}

func diagnosticReadStatus(ctx context.Context, err error) string {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return "timed_out"
	}
	if err != nil {
		return "command_failed"
	}
	return "ok"
}

func diagnosticEnum(value string, allowed ...string) string {
	for _, candidate := range allowed {
		if value == candidate {
			return candidate
		}
	}
	return "unknown"
}

func summarizeTLSLogs(raw string) []tlsDiagnosticEvent {
	events := make([]tlsDiagnosticEvent, 0)
	scanner := bufio.NewScanner(strings.NewReader(raw))
	for lines := 0; lines < 200 && scanner.Scan(); lines++ {
		var entry struct {
			Level  string `json:"level"`
			Logger string `json:"logger"`
			Msg    string `json:"msg"`
			Error  string `json:"error"`
		}
		if json.Unmarshal(scanner.Bytes(), &entry) != nil || (entry.Logger != "tls" && !strings.HasPrefix(entry.Logger, "tls.")) {
			continue
		}
		event := tlsDiagnosticEvent{
			Level: diagnosticEnum(entry.Level, "debug", "info", "warn", "error", "fatal", "panic"),
			Event: diagnosticEnum(entry.Msg, "obtaining certificate", "certificate obtained successfully", "could not get certificate from issuer", "will retry", "trying to solve challenge", "challenge failed", "validations succeeded", "authorization finalized"),
		}
		for _, code := range []string{"badNonce", "caa", "connection", "dns", "incorrectResponse", "internal", "invalidContact", "malformed", "rateLimited", "rejectedIdentifier", "serverInternal", "tls", "unauthorized", "unsupportedIdentifier"} {
			if strings.Contains(entry.Error, "urn:ietf:params:acme:error:"+code) {
				event.Signals = append(event.Signals, "acme:"+code)
			}
		}
		lower := strings.ToLower(entry.Error)
		for _, signal := range []string{"timeout", "deadline exceeded", "connection refused", "no such host", "permission denied", "no space left on device", "certificate signed by unknown authority"} {
			if strings.Contains(lower, signal) {
				event.Signals = append(event.Signals, signal)
			}
		}
		events = append(events, event)
	}
	return events
}

func writeFailureDiagnostics(directory string, report failureDiagnostics) (string, error) {
	file, err := os.CreateTemp(directory, "failure-*.json")
	if err != nil {
		return "", err
	}
	name := file.Name()
	complete := false
	defer func() {
		file.Close()
		if !complete {
			os.Remove(name)
		}
	}()
	if err := json.NewEncoder(file).Encode(report); err != nil {
		return "", err
	}
	if err := file.Sync(); err != nil {
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	if err := syncDirectory(directory); err != nil {
		return "", err
	}
	complete = true
	return name, nil
}
