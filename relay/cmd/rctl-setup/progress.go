package main

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

const (
	ansiClearLine = "\r\033[2K"
	ansiReset     = "\033[0m"
	ansiCyan      = "\033[36m"
	ansiGreen     = "\033[32m"
	ansiRed       = "\033[31m"
)

type cliProgress struct {
	output      io.Writer
	now         func() time.Time
	interactive bool
	color       bool
	started     time.Time
	stepStarted time.Time
	step        int
	message     string
	heading     bool
	spinnerStop chan struct{}
	spinnerDone chan struct{}
}

func newCLIProgress(output io.Writer) *cliProgress {
	interactive := writerIsTerminal(output) && os.Getenv("TERM") != "dumb"
	return &cliProgress{
		output:      output,
		now:         time.Now,
		interactive: interactive,
		color:       interactive && os.Getenv("NO_COLOR") == "",
	}
}

func writerIsTerminal(output io.Writer) bool {
	file, ok := output.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func (p *cliProgress) Step(message string) {
	now := p.now()
	p.stopSpinner()
	if p.started.IsZero() {
		p.started = now
	}
	if p.message != "" {
		p.finishStep("OK", ansiGreen, now)
	}
	if !p.heading {
		fmt.Fprintln(p.output, "\nProgress")
		p.heading = true
	}
	p.step++
	p.message = message
	p.stepStarted = now
	p.writeActive()
	p.startSpinner()
}

func (p *cliProgress) Success(message string) {
	now := p.now()
	p.stopSpinner()
	if p.message != "" {
		p.finishStep("OK", ansiGreen, now)
	}
	if p.started.IsZero() {
		p.started = now
	}
	fmt.Fprintf(p.output, "\n%s %s (%s)\n", p.label("DONE", ansiGreen), message, formatDuration(now.Sub(p.started)))
}

func (p *cliProgress) Fail(message string) {
	now := p.now()
	p.stopSpinner()
	if p.message != "" {
		p.finishStep("FAIL", ansiRed, now)
	}
	if p.started.IsZero() {
		p.started = now
	}
	fmt.Fprintf(p.output, "\n%s %s (%s)\n", p.label("ERROR", ansiRed), message, formatDuration(now.Sub(p.started)))
}

func (p *cliProgress) writeActive() {
	prefix := fmt.Sprintf("[%d] %s", p.step, p.label("RUN", ansiCyan))
	if p.interactive {
		fmt.Fprintf(p.output, "%s  %s  %s", ansiClearLine, prefix, p.message)
		return
	}
	fmt.Fprintf(p.output, "  %s  %s\n", prefix, p.message)
}

func (p *cliProgress) startSpinner() {
	if !p.interactive {
		return
	}
	stop := make(chan struct{})
	done := make(chan struct{})
	p.spinnerStop = stop
	p.spinnerDone = done
	step, message, started := p.step, p.message, p.stepStarted
	go func() {
		defer close(done)
		ticker := time.NewTicker(120 * time.Millisecond)
		defer ticker.Stop()
		frames := [...]string{"|", "/", "-", "\\"}
		frame := 0
		for {
			select {
			case <-stop:
				return
			case now := <-ticker.C:
				fmt.Fprintf(p.output, "%s  [%d] %s %s  %s (%s)", ansiClearLine, step, frames[frame], p.label("RUN", ansiCyan), message, formatDuration(now.Sub(started)))
				frame = (frame + 1) % len(frames)
			}
		}
	}()
}

func (p *cliProgress) stopSpinner() {
	if p.spinnerStop == nil {
		return
	}
	close(p.spinnerStop)
	<-p.spinnerDone
	p.spinnerStop = nil
	p.spinnerDone = nil
}

func (p *cliProgress) finishStep(status, color string, now time.Time) {
	prefix := fmt.Sprintf("[%d] %s", p.step, p.label(status, color))
	duration := formatDuration(now.Sub(p.stepStarted))
	if p.interactive {
		fmt.Fprintf(p.output, "%s  %s  %s (%s)\n", ansiClearLine, prefix, p.message, duration)
	} else {
		fmt.Fprintf(p.output, "  %s  %s (%s)\n", prefix, p.message, duration)
	}
	p.message = ""
}

func (p *cliProgress) label(value, color string) string {
	if !p.color {
		return value
	}
	return color + value + ansiReset
}

func formatDuration(duration time.Duration) string {
	if duration < 0 {
		duration = 0
	}
	if duration < time.Second {
		return fmt.Sprintf("%dms", duration.Round(time.Millisecond)/time.Millisecond)
	}
	if duration < 10*time.Second {
		return fmt.Sprintf("%.1fs", duration.Round(100*time.Millisecond).Seconds())
	}
	duration = duration.Round(time.Second)
	if duration < time.Minute {
		return fmt.Sprintf("%ds", int(duration/time.Second))
	}
	parts := []string{fmt.Sprintf("%dm", int(duration/time.Minute))}
	if seconds := int(duration/time.Second) % 60; seconds != 0 {
		parts = append(parts, fmt.Sprintf("%ds", seconds))
	}
	return strings.Join(parts, " ")
}
