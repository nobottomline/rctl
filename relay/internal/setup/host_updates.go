package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/nobottomline/rctl/relay/internal/releasefeed"
)

type HostUpdatePolicy struct {
	Automatic bool `json:"automatic"`
	HourUTC   int  `json:"hour_utc"`
}

type HostUpdateStatus struct {
	AgentVersion string           `json:"agent_version"`
	Job          *HostUpdateJob   `json:"job,omitempty"`
	Installed    string           `json:"installed"`
	Latest       string           `json:"latest,omitempty"`
	Available    bool             `json:"available"`
	CheckedAt    int64            `json:"checked_at,omitempty"`
	Phase        string           `json:"phase"`
	Target       string           `json:"target,omitempty"`
	Error        string           `json:"error,omitempty"`
	Policy       HostUpdatePolicy `json:"policy"`
}

type HostUpdateJob struct {
	Target      string `json:"target"`
	Phase       string `json:"phase"`
	Error       string `json:"error,omitempty"`
	StartedAt   int64  `json:"started_at"`
	CompletedAt int64  `json:"completed_at,omitempty"`
}

type hostUpdateState struct {
	Schema    int              `json:"schema"`
	Status    HostUpdateStatus `json:"status"`
	Highest   string           `json:"highest,omitempty"`
	Attempted string           `json:"attempted,omitempty"`
}

// HostUpdater owns serialized, durable update jobs independently of the relay
// container. No request controls a path, URL, executable, or shell argument.
type HostUpdater struct {
	mu        sync.Mutex
	state     hostUpdateState
	catalog   *releasefeed.Catalog
	busy      bool
	ctx       context.Context
	wg        sync.WaitGroup
	stateDir  string
	paths     Paths
	version   string
	client    *http.Client
	runner    Runner
	activate  func(string) error
	restart   chan struct{}
	check     func(context.Context) (releasefeed.Catalog, error)
	apply     func(context.Context, releasefeed.Catalog) error
	installed func() (string, error)
	recover   func(context.Context) error
	now       func() time.Time
}

func NewHostUpdater(paths Paths, stateDir, version string) (*HostUpdater, error) {
	u := &HostUpdater{paths: paths, stateDir: stateDir, version: version, now: time.Now, restart: make(chan struct{}, 1), client: releasefeed.Client(), runner: OSRunner{}, activate: activateHostSetup}
	u.state = hostUpdateState{Schema: 1, Status: HostUpdateStatus{Phase: "idle", Policy: HostUpdatePolicy{HourUTC: 3}}}
	raw, err := readRegularFile(filepath.Join(stateDir, "state.json"), 64<<10, 0o600)
	if err == nil {
		if json.Unmarshal(raw, &u.state) != nil || u.state.Schema != 1 || u.state.Status.Policy.HourUTC < 0 || u.state.Status.Policy.HourUTC > 23 {
			return nil, errors.New("invalid host updater state")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	u.installed = func() (string, error) {
		m, err := loadManifest(paths.ManifestPath)
		if err != nil {
			return "", err
		}
		if err := validateOwnershipManifest(m, paths); err != nil {
			return "", err
		}
		return m.Version, nil
	}
	feedURL := releasefeed.StableURL
	if raw, err := readRegularFile(filepath.Join(stateDir, "source.json"), 4096, 0o600); err == nil {
		var source struct {
			URL string `json:"url"`
		}
		if json.Unmarshal(raw, &source) != nil || !releasefeed.ValidCatalogURL(source.URL) {
			return nil, errors.New("invalid root-managed host update source")
		}
		feedURL = source.URL
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	u.check = func(ctx context.Context) (releasefeed.Catalog, error) {
		var buf bytes.Buffer
		if err := releasefeed.Fetch(ctx, releasefeed.Client(), feedURL, releasefeed.MaxCatalog, &buf); err != nil {
			return releasefeed.Catalog{}, err
		}
		return releasefeed.Decode(buf.Bytes(), releasefeed.PublicKey(), time.Now())
	}
	u.apply = u.applyRelease
	u.recover = func(ctx context.Context) error {
		if _, err := os.Lstat(paths.RecoveryPath); errors.Is(err, os.ErrNotExist) {
			return nil
		} else if err != nil {
			return err
		}
		_, err := (RecoveryManager{Paths: paths}).Recover(ctx)
		return err
	}
	return u, nil
}

func (u *HostUpdater) persistLocked() error {
	return writeJSONAtomic(filepath.Join(u.stateDir, "state.json"), u.state, 0o600)
}

func (u *HostUpdater) snapshotLocked() HostUpdateStatus {
	s := u.state.Status
	if s.Job != nil {
		copy := *s.Job
		s.Job = &copy
	}
	s.Available = false
	if u.catalog != nil && u.catalog.Validate(u.now()) == nil {
		cmp, err := releasefeed.Compare(u.catalog.Version, s.Installed)
		s.Available = err == nil && cmp > 0 && !u.busy && s.Phase != "recovery_required" && s.Phase != "storage_error"
	}
	return s
}

func (u *HostUpdater) Status() HostUpdateStatus {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.snapshotLocked()
}

func (u *HostUpdater) setPhase(phase string) error {
	u.mu.Lock()
	defer u.mu.Unlock()
	u.state.Status.Phase = phase
	if u.state.Status.Job != nil {
		u.state.Status.Job.Phase = phase
	}
	return u.persistLocked()
}

// Start resolves interrupted work before accepting new installations. Automatic
// retry of the same failed release is suppressed, including across reboots.
func (u *HostUpdater) Start(ctx context.Context) error {
	u.ctx = ctx
	if err := os.MkdirAll(u.stateDir, 0o700); err != nil {
		return err
	}
	_, checkpointErr := os.Lstat(u.paths.RecoveryPath)
	if checkpointErr != nil && !errors.Is(checkpointErr, os.ErrNotExist) {
		return checkpointErr
	}
	// The lifecycle checkpoint is authoritative even when persisting the job
	// result failed. Re-evaluate a prior recovery failure after operator repair.
	if checkpointErr == nil || u.state.Status.Phase == "installing" || u.state.Status.Phase == "downloading" || u.state.Status.Phase == "recovering" || u.state.Status.Phase == "recovery_required" {
		recoveryCtx, cancel := context.WithTimeout(ctx, 20*time.Minute)
		recoveryErr := u.recover(recoveryCtx)
		cancel()
		if recoveryErr != nil {
			u.state.Status.Phase = "recovery_required"
			u.state.Status.Error = "Recovery needs operator attention. Run rctl-setup recover, then restart rctl-update-agent on the VPS."
		} else {
			u.state.Status.Phase = "interrupted"
			u.state.Status.Error = "The interrupted update was recovered. Check the installed version before retrying."
		}
		if j := u.state.Status.Job; j != nil {
			j.Phase = u.state.Status.Phase
			j.Error = u.state.Status.Error
			j.CompletedAt = u.now().Unix()
		}
	}
	v, err := u.installed()
	if err != nil && u.state.Status.Phase != "recovery_required" {
		return err
	}
	if err == nil {
		u.state.Status.Installed = v
	}
	if u.state.Status.Phase != "recovery_required" {
		entries, err := os.ReadDir(u.stateDir)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			if entry.IsDir() && strings.HasPrefix(entry.Name(), "stage-") {
				if err := os.RemoveAll(filepath.Join(u.stateDir, entry.Name())); err != nil {
					return err
				}
			}
		}
	}
	u.state.Status.AgentVersion = u.version
	if err := u.persistLocked(); err != nil {
		return err
	}
	u.wg.Add(1)
	go func() {
		defer u.wg.Done()
		// Catalog bytes are deliberately not persisted. A recent check timestamp
		// must not suppress verification after a restart or leave 'checking' stuck.
		_ = u.checkRelease(true)
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				u.tick()
			}
		}
	}()
	return nil
}

func (u *HostUpdater) Wait()                    { u.wg.Wait() }
func (u *HostUpdater) Restart() <-chan struct{} { return u.restart }

func (u *HostUpdater) tick() {
	u.mu.Lock()
	s := u.snapshotLocked()
	check := !u.busy && u.now().Unix()-s.CheckedAt >= int64((6*time.Hour).Seconds())
	install := !u.busy && s.Policy.Automatic && u.now().UTC().Hour() == s.Policy.HourUTC && s.Available && u.state.Attempted != s.Latest
	u.mu.Unlock()
	if check {
		_ = u.Check()
	} else if install {
		_ = u.install(s.Latest, true)
	}
}

func (u *HostUpdater) Check() error {
	return u.checkRelease(false)
}

func (u *HostUpdater) checkRelease(force bool) error {
	u.mu.Lock()
	if u.ctx.Err() != nil {
		u.mu.Unlock()
		return errors.New("update service is stopping")
	}
	if u.busy {
		u.mu.Unlock()
		return errors.New("update operation in progress")
	}
	if u.state.Status.Phase == "recovery_required" {
		u.mu.Unlock()
		return errors.New("recovery required")
	}
	if !force && u.now().Unix()-u.state.Status.CheckedAt < 60 {
		u.mu.Unlock()
		return nil
	}
	u.busy = true
	u.state.Status.Phase = "checking"
	if err := u.persistLocked(); err != nil {
		u.busy = false
		u.mu.Unlock()
		return err
	}
	u.wg.Add(1)
	u.mu.Unlock()
	go func() {
		defer u.wg.Done()
		ctx, cancel := context.WithTimeout(u.ctx, 45*time.Second)
		defer cancel()
		c, err := u.check(ctx)
		u.mu.Lock()
		defer u.mu.Unlock()
		u.busy = false
		u.state.Status.CheckedAt = u.now().Unix()
		if err == nil {
			err = c.Validate(u.now())
		}
		if err == nil && u.state.Highest != "" {
			cmp, e := releasefeed.Compare(c.Version, u.state.Highest)
			if e != nil || cmp < 0 {
				err = errors.New("catalog rollback rejected")
			}
		}
		if err != nil {
			u.catalog = nil
			u.state.Status.Phase = "check_failed"
			u.state.Status.Error = "Could not verify the release catalog. No update will be installed."
		} else {
			u.catalog = &c
			u.state.Highest = c.Version
			u.state.Status.Latest = c.Version
			u.state.Status.Phase = "idle"
			u.state.Status.Error = ""
		}
		if u.persistLocked() != nil {
			u.catalog = nil
			u.state.Status.Phase = "storage_error"
			u.state.Status.Error = "Could not persist update state."
		}
	}()
	return nil
}

func (u *HostUpdater) Policy(p HostUpdatePolicy) error {
	if p.HourUTC < 0 || p.HourUTC > 23 {
		return errors.New("invalid maintenance hour")
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.busy {
		return errors.New("update operation in progress")
	}
	old := u.state.Status.Policy
	u.state.Status.Policy = p
	if err := u.persistLocked(); err != nil {
		u.state.Status.Policy = old
		return err
	}
	return nil
}

func (u *HostUpdater) Install(version string) error {
	return u.install(version, false)
}

func (u *HostUpdater) install(version string, automatic bool) error {
	u.mu.Lock()
	if u.ctx.Err() != nil {
		u.mu.Unlock()
		return errors.New("update service is stopping")
	}
	if automatic && (!u.state.Status.Policy.Automatic || u.now().UTC().Hour() != u.state.Status.Policy.HourUTC || u.state.Attempted == version) {
		u.mu.Unlock()
		return errors.New("automatic update is not authorized")
	}
	if u.busy || !u.snapshotLocked().Available || version != u.state.Status.Latest || u.state.Status.Phase == "recovery_required" {
		u.mu.Unlock()
		return errors.New("no verified newer release is available")
	}
	c := *u.catalog
	u.busy = true
	u.state.Status.Phase = "downloading"
	u.state.Status.Target = version
	u.state.Status.Error = ""
	u.state.Attempted = version
	u.state.Status.Job = &HostUpdateJob{Target: version, Phase: "downloading", StartedAt: u.now().Unix()}
	if err := u.persistLocked(); err != nil {
		u.busy = false
		u.state.Status.Phase = "storage_error"
		u.state.Status.Error = "Could not persist update request."
		if j := u.state.Status.Job; j != nil {
			j.Phase = u.state.Status.Phase
			j.Error = u.state.Status.Error
			j.CompletedAt = u.now().Unix()
		}
		u.mu.Unlock()
		return err
	}
	u.wg.Add(1)
	u.mu.Unlock()
	go func() {
		defer u.wg.Done()
		ctx, cancel := context.WithTimeout(u.ctx, 45*time.Minute)
		err := u.apply(ctx, c)
		cancel()
		if err != nil {
			_ = u.setPhase("recovering")
			recoveryCtx, stop := context.WithTimeout(context.Background(), 20*time.Minute)
			recoveryErr := u.recover(recoveryCtx)
			stop()
			u.mu.Lock()
			if recoveryErr != nil {
				u.state.Status.Phase = "recovery_required"
				u.state.Status.Error = "Update recovery needs operator attention. Run rctl-setup recover, then restart rctl-update-agent on the VPS."
			} else {
				u.state.Status.Phase = "failed"
				u.state.Status.Error = "Update did not complete. Check the installed version; automatic retry is paused for this release."
			}
			u.mu.Unlock()
		} else {
			_ = u.setPhase("succeeded")
		}
		v, versionErr := u.installed()
		u.mu.Lock()
		if versionErr == nil {
			u.state.Status.Installed = v
		}
		u.busy = false
		if j := u.state.Status.Job; j != nil {
			j.Phase = u.state.Status.Phase
			j.Error = u.state.Status.Error
			j.CompletedAt = u.now().Unix()
		}
		if u.persistLocked() != nil {
			u.state.Status.Phase = "storage_error"
			u.state.Status.Error = "Could not persist update result."
		}
		u.mu.Unlock()
		if err == nil {
			select {
			case u.restart <- struct{}{}:
			default:
			}
		}
	}()
	return nil
}

func (u *HostUpdater) applyRelease(ctx context.Context, c releasefeed.Catalog) error {
	if err := c.Validate(time.Now()); err != nil {
		return err
	}
	current, err := loadManifest(u.paths.ManifestPath)
	if err != nil {
		return err
	}
	if err := validateOwnershipManifest(current, u.paths); err != nil {
		return err
	}
	cmp, err := releasefeed.Compare(c.Version, current.Version)
	if err != nil || cmp <= 0 {
		return errors.New("target is not newer")
	}
	if runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
		return errors.New("unsupported host architecture")
	}
	stage, err := os.MkdirTemp(u.stateDir, "stage-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	setupName := "rctl-setup_linux_" + runtime.GOARCH
	names := []string{setupName}
	args := []string{"upgrade", "--yes"}
	if current.Config.DevicePackages {
		name := "rctl_" + c.Version + "_iphoneos-arm.deb"
		names = append(names, name)
		args = append(args, "--public-package", filepath.Join(stage, name))
	}
	if current.Config.RootlessDevicePackages {
		name := "rctl_" + c.Version + "_iphoneos-arm64.deb"
		names = append(names, name)
		args = append(args, "--rootless-public-package", filepath.Join(stage, name))
	}
	for _, name := range names {
		if err := releasefeed.Download(ctx, u.client, c, name, filepath.Join(stage, name)); err != nil {
			return err
		}
	}
	bin := filepath.Join(stage, setupName)
	if err := os.Chmod(bin, 0o700); err != nil {
		return err
	}
	runner := u.runner
	metadata, err := runner.Run(ctx, bin, "version")
	if err != nil || !strings.HasPrefix(metadata, "rctl-setup "+c.Version+" (") {
		return errors.New("candidate setup version mismatch")
	}
	if err := u.setPhase("installing"); err != nil {
		return err
	}
	if _, err := runner.Run(ctx, bin, args...); err != nil {
		return errors.New("candidate upgrade failed")
	}
	v, err := u.installed()
	if err != nil || v != c.Version {
		return errors.New("installed version mismatch")
	}
	return u.activate(bin)
}

// Activate only after the candidate's transaction and health checks commit.
// The currently running supervisor remains alive until status is persisted.
func activateHostSetup(bin string) error {
	raw, err := readRegularFile(bin, releasefeed.MaxArtifact, 0o700)
	if err != nil {
		return err
	}
	for _, dst := range []string{HostAgentBinary, "/usr/local/bin/rctl-setup"} {
		if err := writeFileAtomic(dst, raw, 0o755); err != nil {
			return fmt.Errorf("activate verified setup: %w", err)
		}
	}
	return nil
}

func (u *HostUpdater) Handler() http.Handler {
	mux := http.NewServeMux()
	respond := func(w http.ResponseWriter, err error) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if err != nil {
			w.WriteHeader(http.StatusConflict)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "update_request_rejected"})
			return
		}
		_ = json.NewEncoder(w).Encode(u.Status())
	}
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) { respond(w, nil) })
	mux.HandleFunc("POST /check", func(w http.ResponseWriter, r *http.Request) { respond(w, u.Check()) })
	mux.HandleFunc("POST /install", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Version string `json:"version"`
		}
		if err := decodeHostRequest(w, r, &req); err != nil {
			respond(w, err)
			return
		}
		respond(w, u.Install(req.Version))
	})
	mux.HandleFunc("POST /policy", func(w http.ResponseWriter, r *http.Request) {
		var p HostUpdatePolicy
		if err := decodeHostRequest(w, r, &p); err != nil {
			respond(w, err)
			return
		}
		respond(w, u.Policy(p))
	})
	return mux
}

func decodeHostRequest(w http.ResponseWriter, r *http.Request, dst any) error {
	if r.Header.Get("Content-Type") != "application/json" {
		return errors.New("JSON required")
	}
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	d.DisallowUnknownFields()
	if err := d.Decode(dst); err != nil {
		return err
	}
	if err := d.Decode(new(any)); err == io.EOF {
		return nil
	}
	return errors.New("trailing JSON")
}
