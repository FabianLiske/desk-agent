package runner

import (
	"context"
	"os/exec"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/fabianliske/desk-agent/internal/config"
)

func TestBuildCommand_WindowsPS1(t *testing.T) {
	cmd, err := BuildCommand(context.Background(), "windows", `C:\actions\tv-gaming.ps1`, []string{"--extra"})
	if err != nil {
		t.Fatalf("BuildCommand: %v", err)
	}
	if !strings.EqualFold(cmd.Args[0], "powershell.exe") {
		t.Fatalf("interpreter: %v", cmd.Args)
	}
	joined := strings.Join(cmd.Args, " ")
	for _, want := range []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "tv-gaming.ps1", "--extra"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing arg %q in %q", want, joined)
		}
	}
}

func TestBuildCommand_LinuxSh(t *testing.T) {
	cmd, err := BuildCommand(context.Background(), "linux", "/opt/actions/script.sh", []string{"a", "b"})
	if err != nil {
		t.Fatalf("BuildCommand: %v", err)
	}
	if cmd.Args[0] != "/bin/sh" {
		t.Fatalf("interpreter: %v", cmd.Args)
	}
	if cmd.Args[len(cmd.Args)-2] != "a" || cmd.Args[len(cmd.Args)-1] != "b" {
		t.Fatalf("args: %v", cmd.Args)
	}
}

func TestBuildCommand_WindowsRejectsUnknownExt(t *testing.T) {
	if _, err := BuildCommand(context.Background(), "windows", `C:\x.py`, nil); err == nil {
		t.Fatal("expected error for unknown extension")
	}
}

func TestRun_UnknownAction(t *testing.T) {
	r := New(Options{
		ActionsDir: t.TempDir(),
		Actions:    map[string]config.Action{},
		Timeout:    time.Second,
	})
	_, err := r.Run(context.Background(), "nope")
	if err == nil || !strings.Contains(err.Error(), "unknown action") {
		t.Fatalf("expected unknown-action error, got %v", err)
	}
}

// TestRun_Executes injects a stub buildCmd that runs a portable command
// (`cmd /C echo hi` on Windows, `/bin/sh -c 'echo hi'` elsewhere) so we
// can exercise the full Run() path without depending on the embedded
// scripts existing on disk.
func TestRun_Executes(t *testing.T) {
	r := New(Options{
		ActionsDir: t.TempDir(),
		Actions: map[string]config.Action{
			"ping": {Script: dummyScriptName()},
		},
		Timeout: 5 * time.Second,
	})
	r.SetBuildCmd(func(ctx context.Context, _, _ string, _ []string) (*exec.Cmd, error) {
		if runtime.GOOS == "windows" {
			return exec.CommandContext(ctx, "cmd.exe", "/C", "echo", "hi"), nil
		}
		return exec.CommandContext(ctx, "/bin/sh", "-c", "echo hi"), nil
	})
	res, err := r.Run(context.Background(), "ping")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("exit: %d stderr=%q", res.ExitCode, res.Stderr)
	}
	if !strings.Contains(res.Stdout, "hi") {
		t.Fatalf("stdout: %q", res.Stdout)
	}
}

func dummyScriptName() string {
	if runtime.GOOS == "windows" {
		return "ping.ps1"
	}
	return "ping.sh"
}
