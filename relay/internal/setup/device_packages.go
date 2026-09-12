package setup

import "fmt"

// Both install and upgrade validate the complete package set before mutation.
func appendPublicPackages(bundle *Bundle, cfg Config, paths Paths, rootful, rootless string) error {
	for _, lane := range []struct {
		enabled                           bool
		source, destination, architecture string
	}{
		{cfg.DevicePackages, rootful, paths.PublicPackage, "iphoneos-arm"},
		{cfg.RootlessDevicePackages, rootless, paths.RootlessPackage, "iphoneos-arm64"},
	} {
		if !lane.enabled {
			if lane.source != "" {
				return fmt.Errorf("device package generation is not enabled for %s", lane.architecture)
			}
			continue
		}
		raw, info, err := readPublicPackageSource(lane.source)
		if err != nil {
			return err
		}
		if info.Architecture != lane.architecture {
			return fmt.Errorf("public device package architecture %q does not match %s", info.Architecture, lane.architecture)
		}
		if cfg.Release != "" && cfg.Release != "dev" && info.Version != cfg.Release {
			return fmt.Errorf("public device package version %q does not match target release %q", info.Version, cfg.Release)
		}
		bundle.Files = append(bundle.Files, File{Path: lane.destination, Mode: 0o644, Content: raw})
	}
	return nil
}
