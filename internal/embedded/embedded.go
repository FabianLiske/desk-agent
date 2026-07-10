// Package embedded extracts embedded action scripts to a writable location
// on disk on startup so the runner can execute them.
package embedded

import (
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"

	"github.com/fabianliske/desk-agent/assets"
)

// ExtractActions copies the embedded actions for the running OS into a
// writable directory and returns the absolute path to that directory.
//
// The directory layout after extraction mirrors the source:
//
//	<dataDir>/actions/<os>/*.{ps1,sh,bat,py,...}
//
// where <os> is "windows" or "linux". The function returns the path to
// <dataDir>/actions/<os>.
func ExtractActions(logger *slog.Logger) (string, error) {
	base, err := DataDir()
	if err != nil {
		return "", err
	}

	osName := runtime.GOOS
	if osName != "windows" && osName != "linux" {
		return "", fmt.Errorf("unsupported OS %q", osName)
	}

	targetRoot := filepath.Join(base, "actions", osName)
	if err := os.MkdirAll(targetRoot, 0o755); err != nil {
		return "", fmt.Errorf("create actions dir: %w", err)
	}

	srcRoot := "actions/" + osName

	entries, err := fs.ReadDir(assets.Actions, srcRoot)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			logger.Warn("no embedded actions for this OS", "os", osName)
			return targetRoot, nil
		}
		return "", fmt.Errorf("read embedded actions: %w", err)
	}

	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		data, err := fs.ReadFile(assets.Actions, srcRoot+"/"+e.Name())
		if err != nil {
			return "", fmt.Errorf("read %s: %w", e.Name(), err)
		}
		out := filepath.Join(targetRoot, e.Name())
		mode := os.FileMode(0o644)
		if osName == "linux" {
			mode = 0o755
		}
		if err := writeFileAtomic(out, data, mode); err != nil {
			return "", fmt.Errorf("write %s: %w", out, err)
		}
		logger.Debug("extracted action", "name", e.Name(), "path", out)
	}
	return targetRoot, nil
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// DataDir returns the platform-appropriate writable data directory for the agent.
//
//	Windows: %LOCALAPPDATA%\desk-agent
//	Linux:   ${XDG_DATA_HOME:-$HOME/.local/share}/desk-agent
func DataDir() (string, error) {
	switch runtime.GOOS {
	case "windows":
		base := os.Getenv("LOCALAPPDATA")
		if base == "" {
			return "", errors.New("LOCALAPPDATA not set")
		}
		return filepath.Join(base, "desk-agent"), nil
	default:
		if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
			return filepath.Join(xdg, "desk-agent"), nil
		}
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, ".local", "share", "desk-agent"), nil
	}
}
