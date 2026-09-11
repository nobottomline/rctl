package relay

import (
	"context"
	"time"
)

// historyRetentionEvery is how often the purge runs while the relay is up. The
// first pass runs at start so a long-idle relay catches up immediately.
const historyRetentionEvery = time.Hour

func (s *server) runHistoryRetention(ctx context.Context) {
	if s.cfg.HistoryRetention <= 0 {
		return
	}
	ticker := time.NewTicker(historyRetentionEvery)
	defer ticker.Stop()
	for {
		s.applyHistoryRetention(ctx, time.Now())
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// applyHistoryRetention deletes terminal records older than the retention window:
// revoked controllers (tokens cascade) and enrollment tokens that were revoked,
// used, or expired. Sessions already prune on expiry; audit rows are bounded by
// count, never by this. Returns what was removed so tests and the audit event can
// report it.
func (s *server) applyHistoryRetention(ctx context.Context, now time.Time) (controllers, enrollments int64) {
	if s.cfg.HistoryRetention <= 0 {
		return 0, 0
	}
	cutoff := now.Add(-s.cfg.HistoryRetention).Unix()
	if res, err := s.db.ExecContext(ctx, `DELETE FROM controllers WHERE status='revoked' AND revoked_at IS NOT NULL AND revoked_at<?`, cutoff); err == nil {
		controllers, _ = res.RowsAffected()
	} else if s.log != nil {
		s.log.Warn("history retention: controllers", "error", err)
	}
	// A "never" token has expires_at far in the future, so it only qualifies once
	// revoked or used; an expired token qualifies when its expiry is older than the
	// window, not merely past.
	if res, err := s.db.ExecContext(ctx, `
DELETE FROM enrollments
WHERE (revoked_at IS NOT NULL AND revoked_at<?)
   OR (used_at IS NOT NULL AND used_at<?)
   OR (revoked_at IS NULL AND used_at IS NULL AND expires_at<?)`, cutoff, cutoff, cutoff); err == nil {
		enrollments, _ = res.RowsAffected()
	} else if s.log != nil {
		s.log.Warn("history retention: enrollments", "error", err)
	}
	if controllers > 0 || enrollments > 0 {
		s.auditSystem("history_retention_applied", "controllers", controllers, "enrollments", enrollments,
			"retention_seconds", int64(s.cfg.HistoryRetention.Seconds()))
	}
	return controllers, enrollments
}
