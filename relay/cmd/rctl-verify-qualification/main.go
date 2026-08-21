package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/nobottomline/rctl/relay/internal/qualification"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, output, errorOutput io.Writer) int {
	flags := flag.NewFlagSet("rctl-verify-qualification", flag.ContinueOnError)
	flags.SetOutput(errorOutput)
	file := flags.String("file", "", "qualification report JSON")
	tag := flags.String("tag", "", "expected v-prefixed release tag")
	source := flags.String("source-sha", "", "expected 40-character source commit")
	image := flags.String("relay-image", "", "expected digest-pinned relay image")
	checksums := flags.String("checksums-sha256", "", "expected SHA-256 of SHA256SUMS")
	reportDigest := flags.String("report-sha256", "", "expected SHA-256 of the qualification report")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 || *file == "" || *tag == "" || *source == "" || *image == "" || *checksums == "" || *reportDigest == "" {
		fmt.Fprintln(errorOutput, "all qualification verifier flags are required and positional arguments are rejected")
		return 2
	}
	report, raw, err := qualification.Load(*file)
	if err == nil && qualification.Digest(raw) != *reportDigest {
		err = fmt.Errorf("qualification report digest does not match")
	}
	if err == nil {
		err = qualification.Validate(report, qualification.Expected{
			Tag: *tag, SourceSHA: *source, RelayImage: *image, ChecksumsSHA256: *checksums,
		})
	}
	if err != nil {
		fmt.Fprintln(errorOutput, "qualification verification:", err)
		return 1
	}
	fmt.Fprintln(output, "qualification report verified")
	return 0
}
