package releasefeed

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"
)

// Only the repository and its release-asset CDN are used. Neither the browser
// nor signed metadata supplies an arbitrary destination to the privileged agent.
func Client() *http.Client {
	return &http.Client{Timeout: 10 * time.Minute, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 || !allowedURL(req.URL) {
			return errors.New("release redirect rejected")
		}
		return nil
	}}
}

func allowedURL(u *url.URL) bool {
	return u.Scheme == "https" && u.User == nil && u.Port() == "" && (u.Hostname() == "github.com" || u.Hostname() == "release-assets.githubusercontent.com")
}

func Fetch(ctx context.Context, client *http.Client, rawURL string, max int64, dst io.Writer) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil || !allowedURL(req.URL) {
		return errors.New("release URL rejected")
	}
	resp, err := client.Do(req)
	if err != nil {
		return errors.New("release download unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.New("release asset is unavailable")
	}
	n, err := io.Copy(dst, io.LimitReader(resp.Body, max+1))
	if err != nil {
		return errors.New("release download interrupted")
	}
	if n > max {
		return errors.New("release asset exceeds size limit")
	}
	return nil
}

func Download(ctx context.Context, client *http.Client, c Catalog, name, destination string) error {
	a, ok := c.Artifacts[name]
	if !ok {
		return errors.New("artifact is not in the signed release")
	}
	f, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	complete := false
	defer func() {
		f.Close()
		if !complete {
			os.Remove(destination)
		}
	}()
	h := sha256.New()
	if err := Fetch(ctx, client, c.AssetURL(name), a.Size, io.MultiWriter(f, h)); err != nil {
		return err
	}
	i, err := f.Stat()
	if err != nil {
		return err
	}
	if i.Size() != a.Size || hex.EncodeToString(h.Sum(nil)) != a.SHA256 {
		return errors.New("release artifact verification failed")
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	complete = true
	return nil
}
