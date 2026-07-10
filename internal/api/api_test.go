package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/fabianliske/desk-agent/internal/config"
	"github.com/fabianliske/desk-agent/internal/runner"
)

func newTestServer(t *testing.T, token string, actions map[string]config.Action) *httptest.Server {
	t.Helper()
	r := runner.New(runner.Options{
		ActionsDir: t.TempDir(),
		Actions:    actions,
		Timeout:    5 * time.Second,
	})
	// Inject a stub command builder that echoes the action name so we
	// don't need real files on disk.
	r.SetBuildCmd(func(ctx context.Context, _, _ string, _ []string) (*exec.Cmd, error) {
		if runtime.GOOS == "windows" {
			return exec.CommandContext(ctx, "cmd.exe", "/C", "echo", "ok"), nil
		}
		return exec.CommandContext(ctx, "/bin/sh", "-c", "echo ok"), nil
	})

	s := New(Options{
		Token:   token,
		Runner:  r,
		Version: "test",
	})
	ts := httptest.NewServer(s.http.Handler)
	t.Cleanup(ts.Close)
	return ts
}

func TestHealthz(t *testing.T) {
	ts := newTestServer(t, "t", nil)
	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status: %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "ok") {
		t.Fatalf("body: %q", body)
	}
}

func TestListActions_RequiresToken(t *testing.T) {
	ts := newTestServer(t, "sekret", map[string]config.Action{
		"a": {Script: "a.sh"},
	})

	resp, err := http.Get(ts.URL + "/actions")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}

	req, _ := http.NewRequest("GET", ts.URL+"/actions", nil)
	req.Header.Set("Authorization", "Bearer sekret")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var out struct {
		Version string       `json:"version"`
		Actions []actionInfo `json:"actions"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Version != "test" || len(out.Actions) != 1 || out.Actions[0].Name != "a" {
		t.Fatalf("unexpected payload: %+v", out)
	}
}

func TestRunAction_Success(t *testing.T) {
	ts := newTestServer(t, "sekret", map[string]config.Action{
		"a": {Script: "a.sh"},
	})

	req, _ := http.NewRequest("POST", ts.URL+"/action/a", nil)
	req.Header.Set("X-Desk-Agent-Token", "sekret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status: %d", resp.StatusCode)
	}

	var out runResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Action != "a" || out.ExitCode != 0 {
		t.Fatalf("payload: %+v", out)
	}
	if !strings.Contains(out.Stdout, "ok") {
		t.Fatalf("stdout: %q", out.Stdout)
	}
}

func TestRunAction_Unknown(t *testing.T) {
	ts := newTestServer(t, "sekret", map[string]config.Action{})
	req, _ := http.NewRequest("POST", ts.URL+"/action/nope", nil)
	req.Header.Set("Authorization", "Bearer sekret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status: %d", resp.StatusCode)
	}
}

func TestRunAction_RejectsWrongToken(t *testing.T) {
	ts := newTestServer(t, "sekret", map[string]config.Action{
		"a": {Script: "a.sh"},
	})
	req, _ := http.NewRequest("POST", ts.URL+"/action/a", nil)
	req.Header.Set("Authorization", "Bearer nope")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status: %d", resp.StatusCode)
	}
}
