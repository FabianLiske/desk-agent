// Package runner executes allow-listed action scripts.
//
// The runner does exactly two things:
//   - resolve a requested action name against the allow-list from config
//   - execute the corresponding script with an OS-appropriate interpreter
//
// It refuses anything that is not in the allow-list. Arguments from HTTP
// requests are NOT forwarded — only static args from the config are used.
package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/fabianliske/desk-agent/internal/config"
)

// Result captures the outcome of an action invocation.
type Result struct {
	Action   string
	ExitCode int
	Stdout   string
	Stderr   string
	Duration time.Duration
}

// Options configure a Runner.
type Options struct {
	ActionsDir string
	Actions    map[string]config.Action
	Timeout    time.Duration
	Logger     *slog.Logger
}

// Runner executes allow-listed actions.
type Runner struct {
	actionsDir string
	actions    map[string]config.Action
	timeout    time.Duration
	logger     *slog.Logger

	// buildCmd is swappable in tests so unit tests do not spawn real processes.
	buildCmd func(ctx context.Context, goos, scriptPath string, extraArgs []string) (*exec.Cmd, error)
}

// ErrUnknownAction is returned when a requested action name is not
// present in the configured allow-list.
var ErrUnknownAction = errors.New("unknown action")

// New builds a Runner.
func New(opts Options) *Runner {
	if opts.Timeout <= 0 {
		opts.Timeout = 60 * time.Second
	}
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	return &Runner{
		actionsDir: opts.ActionsDir,
		actions:    opts.Actions,
		timeout:    opts.Timeout,
		logger:     opts.Logger,
		buildCmd:   BuildCommand,
	}
}

// Run executes the named action. The name must be present in the allow-list.
// Concurrent invocations are permitted; each spawns its own OS process.
func (r *Runner) Run(ctx context.Context, name string) (*Result, error) {
	action, ok := r.actions[name]
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrUnknownAction, name)
	}
	scriptPath := filepath.Join(r.actionsDir, action.Script)

	runCtx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()

	cmd, err := r.buildCmd(runCtx, runtime.GOOS, scriptPath, action.Args)
	if err != nil {
		return nil, err
	}

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	start := time.Now()
	r.logger.Info("action starting", "action", name, "script", scriptPath)

	err = cmd.Run()
	dur := time.Since(start)

	exitCode := 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			exitCode = ee.ExitCode()
		} else if errors.Is(runCtx.Err(), context.DeadlineExceeded) {
			exitCode = -1
			err = fmt.Errorf("action timed out after %s", r.timeout)
		} else {
			exitCode = -1
		}
	}

	res := &Result{
		Action:   name,
		ExitCode: exitCode,
		Stdout:   strings.TrimRight(stdout.String(), "\r\n"),
		Stderr:   strings.TrimRight(stderr.String(), "\r\n"),
		Duration: dur,
	}
	r.logger.Info("action finished",
		"action", name,
		"exit_code", res.ExitCode,
		"duration", dur.String(),
	)
	return res, err
}

// Actions returns the configured allow-list (for /actions listings).
func (r *Runner) Actions() map[string]config.Action {
	return r.actions
}

// SetBuildCmd overrides the internal command builder. Intended for tests
// (both in this package and callers). Passing nil restores the default.
func (r *Runner) SetBuildCmd(fn func(ctx context.Context, goos, scriptPath string, args []string) (*exec.Cmd, error)) {
	if fn == nil {
		r.buildCmd = BuildCommand
		return
	}
	r.buildCmd = fn
}

// BuildCommand builds an *exec.Cmd for the given OS. Exported so tests in
// other packages (and injected stubs) can drive it directly.
func BuildCommand(ctx context.Context, goos, scriptPath string, extraArgs []string) (*exec.Cmd, error) {
	ext := strings.ToLower(filepath.Ext(scriptPath))

	switch goos {
	case "windows":
		switch ext {
		case ".ps1":
			args := []string{
				"-NoProfile",
				"-NonInteractive",
				"-ExecutionPolicy", "Bypass",
				"-File", scriptPath,
			}
			args = append(args, extraArgs...)
			return exec.CommandContext(ctx, "powershell.exe", args...), nil
		case ".bat", ".cmd":
			args := []string{"/C", scriptPath}
			args = append(args, extraArgs...)
			return exec.CommandContext(ctx, "cmd.exe", args...), nil
		case ".exe":
			return exec.CommandContext(ctx, scriptPath, extraArgs...), nil
		default:
			return nil, fmt.Errorf("unsupported script extension on windows: %q", ext)
		}
	default:
		switch ext {
		case ".sh", "":
			args := []string{scriptPath}
			args = append(args, extraArgs...)
			return exec.CommandContext(ctx, "/bin/sh", args...), nil
		default:
			// Fall back to running the file directly; it is expected to have
			// a shebang and executable bit (set on extraction).
			return exec.CommandContext(ctx, scriptPath, extraArgs...), nil
		}
	}
}
