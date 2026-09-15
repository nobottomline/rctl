package relay

import "testing"

func TestDeviceUpdateUsesDebianOrdering(t *testing.T) {
	for _, tc := range []struct {
		current, target string
		newer           bool
	}{
		{"0.4.0", "0.4.1", true}, {"0.4.1", "0.4.1", false}, {"0.4.2", "0.4.1", false},
		{"0.4.2~test.relaymerge.2", "0.4.1", false}, {"0.4.2~test.relaymerge.2", "0.4.2", true},
		{"0.4.0+relay", "0.4.1", true}, {"0.4.1-1", "0.4.1", false}, {"1:0.4.0", "0.4.1", false},
		{"", "0.4.1", false}, {"not a version", "0.4.1", false},
	} {
		if got := newerDeviceRelease(tc.current, tc.target); got != tc.newer {
			t.Errorf("%q -> %q = %v", tc.current, tc.target, got)
		}
	}
}
