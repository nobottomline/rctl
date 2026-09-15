package main

import (
	"fmt"
	"io"
	"os"

	setup "github.com/nobottomline/rctl/relay/internal/setup"
	"golang.org/x/term"
)

const (
	ansiBold   = "\033[1m"
	ansiYellow = "\033[33m"
)

func writerIsTerminal(output io.Writer) bool {
	file, ok := output.(*os.File)
	return ok && term.IsTerminal(int(file.Fd()))
}

func colorEnabled(output io.Writer) bool {
	return writerIsTerminal(output) && os.Getenv("TERM") != "dumb" && os.Getenv("NO_COLOR") == ""
}

func styled(output io.Writer, value, color string) string {
	if !colorEnabled(output) {
		return value
	}
	return color + value + ansiReset
}

func printHeading(output io.Writer, title string) {
	fmt.Fprintf(output, "\n%s\n", styled(output, title, ansiBold))
}

func printReport(output io.Writer, report setup.Report) {
	for _, check := range report.Checks {
		color := ansiCyan
		switch check.Severity {
		case setup.Pass:
			color = ansiGreen
		case setup.Warn:
			color = ansiYellow
		case setup.Fail:
			color = ansiRed
		}
		fmt.Fprintf(output, "%s %s", styled(output, "["+string(check.Severity)+"]", color), check.Summary)
		if check.Detail != "" {
			fmt.Fprintf(output, ": %s", check.Detail)
		}
		fmt.Fprintln(output)
	}
}

// Style diagnostics without interpreting their text or buffering credentials.
type diagnosticWriter struct{ io.Writer }

func (w diagnosticWriter) Write(p []byte) (int, error) {
	if _, err := io.WriteString(w.Writer, ansiRed); err != nil {
		return 0, err
	}
	n, err := w.Writer.Write(p)
	_, resetErr := io.WriteString(w.Writer, ansiReset)
	if err != nil {
		return n, err
	}
	return n, resetErr
}

func diagnosticOutput(output io.Writer) io.Writer {
	if colorEnabled(output) {
		return diagnosticWriter{output}
	}
	return output
}
