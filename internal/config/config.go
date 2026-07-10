package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Config models the on-disk YAML configuration.
type Config struct {
	Listen        string            `yaml:"listen"`
	Token         string            `yaml:"token"`
	TokenEnv      string            `yaml:"token_env"`
	TimeoutString string            `yaml:"run_timeout"`
	Actions       map[string]Action `yaml:"actions"`
}

// Action describes a single allow-listed action.
//
// Script is the file name of the script relative to the actions directory
// for the running OS (e.g. "tv-gaming.ps1"). Args are static extra args
// forwarded to the interpreter/script.
type Action struct {
	Script      string   `yaml:"script"`
	Args        []string `yaml:"args"`
	Description string   `yaml:"description"`
}

// ListenAddr returns the configured address, defaulting to :8765.
func (c *Config) ListenAddr() string {
	if c.Listen == "" {
		return ":8765"
	}
	return c.Listen
}

// RunTimeout returns the configured run timeout, defaulting to 60s.
func (c *Config) RunTimeout() time.Duration {
	if c.TimeoutString == "" {
		return 60 * time.Second
	}
	d, err := time.ParseDuration(c.TimeoutString)
	if err != nil || d <= 0 {
		return 60 * time.Second
	}
	return d
}

// Load reads the config file. If path is empty, the default OS location is used.
// If no config file exists, an empty config with a warning-friendly zero token is returned.
func Load(path string) (*Config, string, error) {
	if path == "" {
		p, err := DefaultConfigPath()
		if err != nil {
			return nil, "", err
		}
		path = p
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, path, fmt.Errorf("config file not found at %s (create it or pass -config)", path)
		}
		return nil, path, err
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, path, fmt.Errorf("parse yaml: %w", err)
	}

	if cfg.TokenEnv != "" {
		if v := os.Getenv(cfg.TokenEnv); v != "" {
			cfg.Token = v
		}
	}

	if err := cfg.validate(); err != nil {
		return nil, path, err
	}
	return &cfg, path, nil
}

func (c *Config) validate() error {
	if strings.TrimSpace(c.Token) == "" {
		return errors.New("token is empty: set 'token' or 'token_env' in the config")
	}
	for name, a := range c.Actions {
		if !validActionName(name) {
			return fmt.Errorf("invalid action name %q: only [a-z0-9_] allowed", name)
		}
		if strings.TrimSpace(a.Script) == "" {
			return fmt.Errorf("action %q has empty script", name)
		}
		if strings.ContainsAny(a.Script, `/\`) {
			return fmt.Errorf("action %q script must not contain path separators: %q", name, a.Script)
		}
	}
	return nil
}

func validActionName(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= '0' && r <= '9':
		case r == '_':
		default:
			return false
		}
	}
	return true
}

// DefaultConfigPath returns the OS-specific default config path.
func DefaultConfigPath() (string, error) {
	switch runtime.GOOS {
	case "windows":
		base := os.Getenv("APPDATA")
		if base == "" {
			return "", errors.New("APPDATA not set")
		}
		return filepath.Join(base, "desk-agent", "config.yaml"), nil
	default:
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, ".config", "desk-agent", "config.yaml"), nil
	}
}
