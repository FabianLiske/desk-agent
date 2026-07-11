package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/fabianliske/desk-agent/internal/api"
	"github.com/fabianliske/desk-agent/internal/config"
	"github.com/fabianliske/desk-agent/internal/discordrpc"
	"github.com/fabianliske/desk-agent/internal/embedded"
	"github.com/fabianliske/desk-agent/internal/runner"
)

var (
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "desk-agent: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		configPath  string
		showVersion bool
		discordAuth bool
		logLevel    string
	)

	flag.StringVar(&configPath, "config", "", "path to config file (yaml). If empty, the default location for the OS is used.")
	flag.BoolVar(&showVersion, "version", false, "print version and exit")
	flag.BoolVar(&discordAuth, "discord-auth", false, "authorize Discord RPC and cache the OAuth token, then exit")
	flag.StringVar(&logLevel, "log-level", "info", "log level: debug|info|warn|error")
	flag.Parse()

	if showVersion {
		fmt.Printf("desk-agent %s (commit %s, built %s)\n", version, commit, date)
		return nil
	}

	logger := newLogger(logLevel)
	slog.SetDefault(logger)

	discordClient, discordConfigured, err := newDiscordClient(logger)
	if err != nil {
		return fmt.Errorf("discord rpc config: %w", err)
	}

	if discordAuth {
		if !discordConfigured {
			return errors.New("discord rpc is not configured: set DISCORD_CLIENT_ID and DISCORD_CLIENT_SECRET")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		if err := discordClient.Authorize(ctx); err != nil {
			return fmt.Errorf("discord auth: %w", err)
		}
		fmt.Printf("discord rpc token cached at %s\n", discordClient.TokenCache())
		return nil
	}

	logger.Info("starting desk-agent",
		"version", version,
		"commit", commit,
		"date", date,
	)

	cfg, cfgPath, err := config.Load(configPath)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	logger.Info("config loaded", "path", cfgPath)

	actionsDir, err := embedded.ExtractActions(logger)
	if err != nil {
		return fmt.Errorf("extract actions: %w", err)
	}
	logger.Info("actions extracted", "dir", actionsDir)

	displayConfigDir, err := embedded.ExtractDisplayConfigs(logger)
	if err != nil {
		return fmt.Errorf("extract display configs: %w", err)
	}
	if displayConfigDir != "" {
		logger.Info("display configs extracted", "dir", displayConfigDir)
	}
	run := runner.New(runner.Options{
		ActionsDir: actionsDir,
		Actions:    cfg.Actions,
		Timeout:    cfg.RunTimeout(),
		Logger:     logger,
	})

	var discordAPI api.Discord
	if discordConfigured {
		discordAPI = discordClient
	}

	srv := api.New(api.Options{
		Addr:    cfg.ListenAddr(),
		Token:   cfg.Token,
		Runner:  run,
		Discord: discordAPI,
		Logger:  logger,
		Version: version,
	})

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	errCh := make(chan error, 1)
	go func() {
		logger.Info("http server listening", "addr", cfg.ListenAddr())
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case <-ctx.Done():
		logger.Info("shutdown requested")
	case err := <-errCh:
		return fmt.Errorf("http server: %w", err)
	}

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("http shutdown: %w", err)
	}
	logger.Info("desk-agent stopped cleanly")
	return nil
}

func newDiscordClient(logger *slog.Logger) (*discordrpc.Client, bool, error) {
	cfg, ok, err := discordrpc.ConfigFromEnv()
	if err != nil || !ok {
		return nil, false, err
	}
	logger.Info("discord rpc configured", "token_cache", cfg.TokenCache)
	return discordrpc.New(cfg, logger), true, nil
}

func newLogger(level string) *slog.Logger {
	var lvl slog.Level
	switch level {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	handler := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: lvl})
	return slog.New(handler)
}


