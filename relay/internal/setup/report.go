package setup

import (
	"encoding/json"
	"fmt"
	"io"
)

type Severity string

const (
	Pass Severity = "pass"
	Warn Severity = "warn"
	Fail Severity = "fail"
)

type Check struct {
	ID       string   `json:"id"`
	Severity Severity `json:"severity"`
	Summary  string   `json:"summary"`
	Detail   string   `json:"detail,omitempty"`
}

type Report struct {
	Checks []Check `json:"checks"`
}

func (r Report) Failed() bool {
	for _, check := range r.Checks {
		if check.Severity == Fail {
			return true
		}
	}
	return false
}

func (r Report) WriteText(w io.Writer) {
	for _, check := range r.Checks {
		fmt.Fprintf(w, "[%s] %s", check.Severity, check.Summary)
		if check.Detail != "" {
			fmt.Fprintf(w, ": %s", check.Detail)
		}
		fmt.Fprintln(w)
	}
}

func (r Report) WriteJSON(w io.Writer) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(r)
}
