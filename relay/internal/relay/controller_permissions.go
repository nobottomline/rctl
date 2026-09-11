package relay

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
)

// The revision is a compare-and-swap token, not a credential. All grant changes
// close existing sessions; channels are never promoted in place.
func (s *server) handleUpdateControllerPermissions(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Scopes           []string `json:"scopes"`
		ExpectedRevision int64    `json:"expected_revision"`
	}
	if readStrictJSON(r, &req) != nil || req.ExpectedRevision < 1 || req.ExpectedRevision >= 9007199254740991 {
		writeErr(w, http.StatusBadRequest, "invalid_permissions_request")
		return
	}
	scopes, err := normalizeControllerScopes(req.Scopes)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_scopes")
		return
	}
	id := r.PathValue("id")
	s.controllerGrantsMu.Lock()
	defer s.controllerGrantsMu.Unlock()
	var status, previous string
	var revision int64
	err = s.db.QueryRowContext(r.Context(), `SELECT status,scopes_json,authorization_revision FROM controllers WHERE id=?`, id).Scan(&status, &previous, &revision)
	if errors.Is(err, sql.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "controller_not_found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "controller_permissions_failed")
		return
	}
	if status != "active" {
		writeErr(w, http.StatusConflict, "controller_revoked")
		return
	}
	if revision != req.ExpectedRevision {
		writeErr(w, http.StatusConflict, "controller_permissions_changed")
		return
	}
	encoded, _ := json.Marshal(scopes)
	var oldScopes []string
	_ = json.Unmarshal([]byte(previous), &oldScopes)
	normalizedOld, _ := normalizeControllerScopes(oldScopes)
	oldJSON, _ := json.Marshal(normalizedOld)
	changed := string(oldJSON) != string(encoded)
	if changed {
		res, err := s.db.ExecContext(r.Context(), `UPDATE controllers SET scopes_json=?,authorization_revision=authorization_revision+1 WHERE id=? AND status='active' AND authorization_revision=?`, string(encoded), id, revision)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "controller_permissions_failed")
			return
		}
		if n, _ := res.RowsAffected(); n != 1 {
			writeErr(w, http.StatusConflict, "controller_permissions_changed")
			return
		}
		revision++
		s.closeControllerSignals(id)
		s.audit(r, "controller_permissions_changed", "controller_id", id, "previous_scopes", normalizedOld, "scopes", scopes, "authorization_revision", revision)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "scopes": scopes, "authorization_revision": revision, "changed": changed})
}

func (s *server) controllerGrantCurrent(ctx context.Context, id string, revision int64) bool {
	var current int64
	var status string
	err := s.db.QueryRowContext(ctx, `SELECT authorization_revision,status FROM controllers WHERE id=?`, id).Scan(&current, &status)
	return err == nil && status == "active" && revision > 0 && current == revision
}
