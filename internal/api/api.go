// Package api implements the HTTP surface of the desk agent.
//
// The API is intentionally tiny:
//
//	GET  /healthz            -> "ok"
//	GET  /actions            -> JSON list of allow-listed actions
//	POST /action/{name}      -> execute the named action
//
// All non-/healthz endpoints require a bearer token in the Authorization
// header (or an "X-Desk-Agent-Token" header for clients that cannot set
// Authorization). Requests without a valid token get a 401.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/fabianliske/desk-agent/internal/discordrpc"
	"github.com/fabianliske/desk-agent/internal/runner"
)

// Options configure a Server.
type Options struct {
	Addr    string
	Token   string
	Runner  *runner.Runner
	Discord Discord
	Logger  *slog.Logger
	Version string
}

// Discord is the Discord control surface used by the HTTP API.
type Discord interface {
	State(context.Context) (discordrpc.State, error)
	SetMute(context.Context, bool) (discordrpc.State, error)
	SetDeaf(context.Context, bool) (discordrpc.State, error)
	ToggleMute(context.Context) (discordrpc.State, discordrpc.State, error)
	ToggleDeaf(context.Context) (discordrpc.State, discordrpc.State, error)
}

// Server wraps http.Server with the agent's routes.
type Server struct {
	http    *http.Server
	logger  *slog.Logger
	token   string
	runner  *runner.Runner
	discord Discord
	version string
}

// New constructs the HTTP server. Call ListenAndServe / Shutdown as usual.
func New(opts Options) *Server {
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	s := &Server{
		logger:  opts.Logger,
		token:   opts.Token,
		runner:  opts.Runner,
		discord: opts.Discord,
		version: opts.Version,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /actions", s.requireToken(s.handleListActions))
	mux.HandleFunc("POST /action/{name}", s.requireToken(s.handleRunAction))
	mux.HandleFunc("GET /discord/state", s.requireToken(s.handleDiscordState))
	mux.HandleFunc("POST /discord/mute/toggle", s.requireToken(s.handleDiscordToggleMute))
	mux.HandleFunc("POST /discord/deafen/toggle", s.requireToken(s.handleDiscordToggleDeaf))
	mux.HandleFunc("POST /discord/mute", s.requireToken(s.handleDiscordSetMute(true)))
	mux.HandleFunc("POST /discord/unmute", s.requireToken(s.handleDiscordSetMute(false)))
	mux.HandleFunc("POST /discord/deafen", s.requireToken(s.handleDiscordSetDeaf(true)))
	mux.HandleFunc("POST /discord/undeafen", s.requireToken(s.handleDiscordSetDeaf(false)))

	s.http = &http.Server{
		Addr:              opts.Addr,
		Handler:           s.withLogging(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      2 * time.Minute,
		IdleTimeout:       60 * time.Second,
	}
	return s
}

func (s *Server) handleDiscordState(w http.ResponseWriter, r *http.Request) {
	if !s.discordAvailable(w) {
		return
	}
	state, err := s.discord.State(r.Context())
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"discord": state,
	})
}

func (s *Server) handleDiscordToggleMute(w http.ResponseWriter, r *http.Request) {
	if !s.discordAvailable(w) {
		return
	}
	before, after, err := s.discord.ToggleMute(r.Context())
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":     true,
		"before": before,
		"after":  after,
	})
}

func (s *Server) handleDiscordToggleDeaf(w http.ResponseWriter, r *http.Request) {
	if !s.discordAvailable(w) {
		return
	}
	before, after, err := s.discord.ToggleDeaf(r.Context())
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":     true,
		"before": before,
		"after":  after,
	})
}

func (s *Server) handleDiscordSetMute(mute bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.discordAvailable(w) {
			return
		}
		state, err := s.discord.SetMute(r.Context(), mute)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":      true,
			"discord": state,
		})
	}
}

func (s *Server) handleDiscordSetDeaf(deaf bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.discordAvailable(w) {
			return
		}
		state, err := s.discord.SetDeaf(r.Context(), deaf)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":      true,
			"discord": state,
		})
	}
}

func (s *Server) discordAvailable(w http.ResponseWriter) bool {
	if s.discord != nil {
		return true
	}
	writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "discord rpc is not configured"})
	return false
}

// ListenAndServe forwards to the underlying http.Server.
func (s *Server) ListenAndServe() error { return s.http.ListenAndServe() }

// Shutdown forwards to the underlying http.Server.
func (s *Server) Shutdown(ctx context.Context) error { return s.http.Shutdown(ctx) }

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintln(w, "ok")
}

type actionInfo struct {
	Name        string `json:"name"`
	Script      string `json:"script"`
	Description string `json:"description,omitempty"`
}

func (s *Server) handleListActions(w http.ResponseWriter, _ *http.Request) {
	acts := s.runner.Actions()
	out := make([]actionInfo, 0, len(acts))
	for name, a := range acts {
		out = append(out, actionInfo{
			Name:        name,
			Script:      a.Script,
			Description: a.Description,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"version": s.version,
		"actions": out,
	})
}

type runResponse struct {
	Action   string `json:"action"`
	ExitCode int    `json:"exit_code"`
	Stdout   string `json:"stdout,omitempty"`
	Stderr   string `json:"stderr,omitempty"`
	Duration string `json:"duration"`
	Error    string `json:"error,omitempty"`
}

func (s *Server) handleRunAction(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	res, err := s.runner.Run(r.Context(), name)

	if errors.Is(err, runner.ErrUnknownAction) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}
	if res == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": errString(err),
		})
		return
	}

	resp := runResponse{
		Action:   res.Action,
		ExitCode: res.ExitCode,
		Stdout:   res.Stdout,
		Stderr:   res.Stderr,
		Duration: res.Duration.String(),
	}
	status := http.StatusOK
	if err != nil {
		resp.Error = err.Error()
		status = http.StatusInternalServerError
	}
	writeJSON(w, status, resp)
}

func (s *Server) requireToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		presented := extractToken(r)
		if !tokensEqual(presented, s.token) {
			w.Header().Set("WWW-Authenticate", `Bearer realm="desk-agent"`)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	}
}

func (s *Server) withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		lrw := &loggingResponseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(lrw, r)
		s.logger.Info("http request",
			"method", r.Method,
			"path", r.URL.Path,
			"remote", clientIP(r),
			"status", lrw.status,
			"duration", time.Since(start).String(),
		)
	})
}

type loggingResponseWriter struct {
	http.ResponseWriter
	status int
}

func (lrw *loggingResponseWriter) WriteHeader(code int) {
	lrw.status = code
	lrw.ResponseWriter.WriteHeader(code)
}

func extractToken(r *http.Request) string {
	if h := r.Header.Get("Authorization"); h != "" {
		if strings.HasPrefix(h, "Bearer ") {
			return strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
		}
	}
	return strings.TrimSpace(r.Header.Get("X-Desk-Agent-Token"))
}

func tokensEqual(presented, expected string) bool {
	if expected == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(presented), []byte(expected)) == 1
}

func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if comma := strings.IndexByte(xff, ','); comma > 0 {
			return strings.TrimSpace(xff[:comma])
		}
		return strings.TrimSpace(xff)
	}
	return r.RemoteAddr
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
