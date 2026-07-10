package config

import (
	"os"
	"path/filepath"
	"testing"
)

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	return p
}

func TestLoad_Valid(t *testing.T) {
	p := writeConfig(t, `
listen: ":9000"
token: "hunter2"
run_timeout: "30s"
actions:
  tv_gaming:
    script: tv-gaming.ps1
    description: "TV"
`)
	cfg, _, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.ListenAddr() != ":9000" {
		t.Fatalf("addr: %q", cfg.ListenAddr())
	}
	if cfg.Token != "hunter2" {
		t.Fatalf("token: %q", cfg.Token)
	}
	if cfg.RunTimeout().Seconds() != 30 {
		t.Fatalf("timeout: %v", cfg.RunTimeout())
	}
	if _, ok := cfg.Actions["tv_gaming"]; !ok {
		t.Fatalf("action missing")
	}
}

func TestLoad_TokenFromEnv(t *testing.T) {
	t.Setenv("MY_TOKEN", "from-env")
	p := writeConfig(t, `
token_env: "MY_TOKEN"
actions:
  a:
    script: a.sh
`)
	cfg, _, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Token != "from-env" {
		t.Fatalf("token from env not applied: %q", cfg.Token)
	}
}

func TestLoad_DefaultsWhenFieldsMissing(t *testing.T) {
	p := writeConfig(t, `
token: t
`)
	cfg, _, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.ListenAddr() != ":8765" {
		t.Fatalf("default addr: %q", cfg.ListenAddr())
	}
	if cfg.RunTimeout().Seconds() != 60 {
		t.Fatalf("default timeout: %v", cfg.RunTimeout())
	}
	if len(cfg.Actions) != 0 {
		t.Fatalf("expected no actions, got %d", len(cfg.Actions))
	}
}

func TestValidate_RejectsInvalidNames(t *testing.T) {
	cases := []string{
		`token: t
actions:
  TV_Gaming:
    script: x.ps1
`,
		`token: t
actions:
  "with space":
    script: x.ps1
`,
		`token: t
actions:
  ok:
    script: "sub/x.ps1"
`,
	}
	for i, body := range cases {
		p := writeConfig(t, body)
		if _, _, err := Load(p); err == nil {
			t.Fatalf("case %d: expected validation error", i)
		}
	}
}

func TestValidate_EmptyToken(t *testing.T) {
	p := writeConfig(t, `
actions:
  a:
    script: a.sh
`)
	if _, _, err := Load(p); err == nil {
		t.Fatal("expected error for empty token")
	}
}

func TestLoad_MissingFile(t *testing.T) {
	dir := t.TempDir()
	if _, _, err := Load(filepath.Join(dir, "nope.yaml")); err == nil {
		t.Fatal("expected error for missing file")
	}
}
