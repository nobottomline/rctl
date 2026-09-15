package setup

import (
	"fmt"
	"reflect"
	"testing"
)

func TestDomainHintsAreNamesNotURLsOrControlSequences(t *testing.T) {
	got := normalizeDomainSuggestions([]string{"Example.COM.", "example.com", "relay.example.com", "localhost", "host.local", "127.0.0.1", "*.example.com", "example.com/path", "example.com:443", "example.com\x1b[31m", "user@example.com"})
	want := []string{"example.com", "relay.example.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v", got)
	}
}

func TestDomainHintsSupportHundredsWithoutDuplicates(t *testing.T) {
	var hints []string
	for i := 0; i < 700; i++ {
		hints = append(hints, fmt.Sprintf("site-%03d.example.com", i))
	}
	hints = append(hints, hints...)
	if got := normalizeDomainSuggestions(hints); len(got) != 700 {
		t.Fatalf("got %d domains", len(got))
	}
}
