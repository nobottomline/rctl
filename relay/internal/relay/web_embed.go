package relay

import (
	"embed"
	"io/fs"
	"net/http"
)

// webdist holds the built admin SPA (relay/web-admin). It is committed so the
// relay builds with plain `go build` — run `make web` (or `npm run build` in
// web-admin) to regenerate it after changing the UI.
//
//go:embed all:webdist
var webAdminEmbed embed.FS

func adminFS() fs.FS {
	sub, err := fs.Sub(webAdminEmbed, "webdist")
	if err != nil {
		panic(err)
	}
	return sub
}

// handleAdminAssets serves the embedded SPA under /admin/ (assets resolve at
// /admin/assets/...; the SPA's base is /admin/). Unknown sub-paths fall through
// to index.html so client-side routing keeps working.
func (s *server) handleAdminAssets() http.Handler {
	dist := adminFS()
	fileServer := http.StripPrefix("/admin/", http.FileServerFS(dist))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rel := r.URL.Path[len("/admin/"):]
		if rel != "" {
			if f, err := dist.Open(rel); err == nil {
				_ = f.Close()
				fileServer.ServeHTTP(w, r)
				return
			}
		}
		serveAdminIndex(w, r, dist)
	})
}

func (s *server) handleAdminRoot(w http.ResponseWriter, r *http.Request) {
	serveAdminIndex(w, r, adminFS())
}

func serveAdminIndex(w http.ResponseWriter, r *http.Request, dist fs.FS) {
	data, err := fs.ReadFile(dist, "index.html")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "admin_ui_missing")
		return
	}
	w.Header().Set("Cache-Control", "no-cache")
	writeText(w, http.StatusOK, "text/html; charset=utf-8", string(data))
}
