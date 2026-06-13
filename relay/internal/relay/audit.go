package relay

import "net/http"

func (s *server) audit(r *http.Request, event string, args ...any) {
	if s.log == nil {
		return
	}
	fields := []any{
		"event", event,
		"remote", s.clientIP(r),
		"method", r.Method,
		"path", r.URL.Path,
	}
	fields = append(fields, args...)
	s.log.Info("audit", fields...)
}
