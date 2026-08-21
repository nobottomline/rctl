package setup

import "path/filepath"

type Paths struct {
	EtcDir        string
	OptDir        string
	DataDir       string
	RelayDataDir  string
	CaddyDataDir  string
	CaddyConfDir  string
	BackupDir     string
	LogDir        string
	StateDir      string
	LockPath      string
	RecoveryPath  string
	ManifestPath  string
	RelayEnv      string
	Compose       string
	Caddyfile     string
	Coturn        string
	PublicPackage string
}

func DefaultPaths() Paths { return pathsWithPrefix("") }

func PathsUnder(root string) Paths { return pathsWithPrefix(filepath.Clean(root)) }

func pathsWithPrefix(root string) Paths {
	join := func(path string) string {
		if root == "" || root == "." || root == "/" {
			return path
		}
		return filepath.Join(root, path[1:])
	}
	p := Paths{
		EtcDir: join("/etc/rctl"), OptDir: join("/opt/rctl"), DataDir: join("/var/lib/rctl"),
		BackupDir: join("/var/backups/rctl"), LogDir: join("/var/log/rctl-setup"), StateDir: join("/var/lib/rctl/setup"),
		LockPath: join("/var/lock/rctl-setup.lock"), ManifestPath: join("/var/lib/rctl/setup/ownership.json"),
		RecoveryPath: join("/var/log/rctl-setup/recovery.json"),
		RelayEnv:     join("/etc/rctl/relay.env"), Compose: join("/opt/rctl/compose.json"),
		Caddyfile: join("/opt/rctl/Caddyfile"), Coturn: join("/etc/rctl/turnserver.conf"),
		PublicPackage: join("/opt/rctl/rctl-public.deb"),
	}
	p.RelayDataDir = filepath.Join(p.DataDir, "relay")
	p.CaddyDataDir = filepath.Join(p.DataDir, "caddy", "data")
	p.CaddyConfDir = filepath.Join(p.DataDir, "caddy", "config")
	return p
}
