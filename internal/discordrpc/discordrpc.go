package discordrpc

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	opHandshake = 0
	opFrame     = 1

	defaultRedirectURI = "http://localhost"
	defaultScopes      = "rpc"
)

// State is the Discord voice state surface the agent cares about.
type State struct {
	Mute bool `json:"mute"`
	Deaf bool `json:"deaf"`
}

// Config holds the local Discord RPC/OAuth settings.
type Config struct {
	ClientID     string
	ClientSecret string
	RedirectURI  string
	Scopes       []string
	TokenCache   string
}

// Client talks to the local Discord IPC socket.
type Client struct {
	cfg    Config
	http   *http.Client
	logger *slog.Logger
	mu     sync.Mutex
}

type session struct {
	client *Client
	conn   net.Conn
}

type token struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type,omitempty"`
	Scope        string `json:"scope,omitempty"`
	ExpiresIn    int64  `json:"expires_in,omitempty"`
	ExpiresAt    int64  `json:"expires_at,omitempty"`
}

type rpcResponse struct {
	Cmd   string          `json:"cmd,omitempty"`
	Data  json.RawMessage `json:"data,omitempty"`
	Evt   *string         `json:"evt"`
	Nonce string          `json:"nonce"`
	Code  int             `json:"code,omitempty"`
	Msg   string          `json:"message,omitempty"`
}

type voiceSettings struct {
	Mute bool `json:"mute"`
	Deaf bool `json:"deaf"`
}

// ConfigFromEnv reads Discord RPC settings from environment variables.
func ConfigFromEnv() (Config, bool, error) {
	cfg := Config{
		ClientID:     os.Getenv("DISCORD_CLIENT_ID"),
		ClientSecret: os.Getenv("DISCORD_CLIENT_SECRET"),
		RedirectURI:  getenvDefault("DISCORD_REDIRECT_URI", defaultRedirectURI),
		Scopes:       strings.Fields(getenvDefault("DISCORD_SCOPES", defaultScopes)),
		TokenCache:   os.Getenv("DISCORD_TOKEN_CACHE"),
	}
	if cfg.ClientID == "" && cfg.ClientSecret == "" {
		return Config{}, false, nil
	}
	if cfg.ClientID == "" || cfg.ClientSecret == "" {
		return Config{}, false, errors.New("DISCORD_CLIENT_ID and DISCORD_CLIENT_SECRET must both be set")
	}
	if cfg.TokenCache == "" {
		p, err := defaultTokenCache()
		if err != nil {
			return Config{}, false, err
		}
		cfg.TokenCache = p
	}
	if len(cfg.Scopes) == 0 {
		cfg.Scopes = []string{defaultScopes}
	}
	return cfg, true, nil
}

// New creates a Discord RPC client.
func New(cfg Config, logger *slog.Logger) *Client {
	if logger == nil {
		logger = slog.Default()
	}
	return &Client{
		cfg:    cfg,
		http:   &http.Client{Timeout: 15 * time.Second},
		logger: logger,
	}
}

// TokenCache returns the token cache path.
func (c *Client) TokenCache() string { return c.cfg.TokenCache }

// Authorize performs the interactive one-time Discord authorization.
func (c *Client) Authorize(ctx context.Context) error {
	conn, err := c.connect(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := c.handshake(ctx, conn); err != nil {
		return err
	}
	tok, err := c.authorize(ctx, conn)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.saveToken(tok)
}

// State returns the current Discord mute/deafen state.
func (c *Client) State(ctx context.Context) (State, error) {
	s, err := c.open(ctx)
	if err != nil {
		return State{}, err
	}
	defer s.Close()
	return s.State(ctx)
}

func (s *session) State(ctx context.Context) (State, error) {
	var data voiceSettings
	if err := s.call(ctx, "GET_VOICE_SETTINGS", map[string]any{}, &data); err != nil {
		return State{}, err
	}
	return State{Mute: data.Mute, Deaf: data.Deaf}, nil
}

// SetMute sets Discord mute and returns the resulting state.
func (c *Client) SetMute(ctx context.Context, mute bool) (State, error) {
	s, err := c.open(ctx)
	if err != nil {
		return State{}, err
	}
	defer s.Close()
	return s.SetMute(ctx, mute)
}

func (s *session) SetMute(ctx context.Context, mute bool) (State, error) {
	if err := s.call(ctx, "SET_VOICE_SETTINGS", map[string]any{"mute": mute}, nil); err != nil {
		return State{}, err
	}
	return s.State(ctx)
}

// SetDeaf sets Discord deafen and returns the resulting state.
func (c *Client) SetDeaf(ctx context.Context, deaf bool) (State, error) {
	s, err := c.open(ctx)
	if err != nil {
		return State{}, err
	}
	defer s.Close()
	return s.SetDeaf(ctx, deaf)
}

func (s *session) SetDeaf(ctx context.Context, deaf bool) (State, error) {
	if err := s.call(ctx, "SET_VOICE_SETTINGS", map[string]any{"deaf": deaf}, nil); err != nil {
		return State{}, err
	}
	return s.State(ctx)
}

// ToggleMute toggles Discord mute and returns before/after states.
func (c *Client) ToggleMute(ctx context.Context) (State, State, error) {
	s, err := c.open(ctx)
	if err != nil {
		return State{}, State{}, err
	}
	defer s.Close()
	before, err := s.State(ctx)
	if err != nil {
		return State{}, State{}, err
	}
	after, err := s.SetMute(ctx, !before.Mute)
	return before, after, err
}

// ToggleDeaf toggles Discord deafen and returns before/after states.
func (c *Client) ToggleDeaf(ctx context.Context) (State, State, error) {
	s, err := c.open(ctx)
	if err != nil {
		return State{}, State{}, err
	}
	defer s.Close()
	before, err := s.State(ctx)
	if err != nil {
		return State{}, State{}, err
	}
	after, err := s.SetDeaf(ctx, !before.Deaf)
	return before, after, err
}

func (c *Client) call(ctx context.Context, cmd string, args map[string]any, out any) error {
	s, err := c.open(ctx)
	if err != nil {
		return err
	}
	defer s.Close()
	return s.call(ctx, cmd, args, out)
}

func (c *Client) open(ctx context.Context) (*session, error) {
	conn, err := c.connect(ctx)
	if err != nil {
		return nil, err
	}

	if _, err := c.handshake(ctx, conn); err != nil {
		conn.Close()
		return nil, err
	}
	tok, err := c.token(ctx, conn)
	if err != nil {
		conn.Close()
		return nil, err
	}
	if _, err := c.rpc(ctx, conn, "AUTHENTICATE", map[string]any{"access_token": tok.AccessToken}); err != nil {
		conn.Close()
		return nil, fmt.Errorf("authenticate: %w", err)
	}
	return &session{client: c, conn: conn}, nil
}

func (s *session) Close() error {
	if s == nil || s.conn == nil {
		return nil
	}
	return s.conn.Close()
}

func (s *session) call(ctx context.Context, cmd string, args map[string]any, out any) error {
	resp, err := s.client.rpc(ctx, s.conn, cmd, args)
	if err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(resp.Data, out)
}

func (c *Client) token(ctx context.Context, conn net.Conn) (*token, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	tok, err := c.loadToken()
	if err == nil && tok.Valid() {
		return tok, nil
	}
	if err == nil && tok.RefreshToken != "" {
		if refreshed, refreshErr := c.refresh(ctx, tok.RefreshToken); refreshErr == nil {
			if err := c.saveToken(refreshed); err != nil {
				return nil, err
			}
			return refreshed, nil
		} else {
			c.logger.Warn("discord token refresh failed; falling back to authorize", "error", refreshErr)
		}
	}

	tok, err = c.authorize(ctx, conn)
	if err != nil {
		return nil, err
	}
	if err := c.saveToken(tok); err != nil {
		return nil, err
	}
	return tok, nil
}

func (c *Client) authorize(ctx context.Context, conn net.Conn) (*token, error) {
	resp, err := c.rpc(ctx, conn, "AUTHORIZE", map[string]any{
		"client_id": c.cfg.ClientID,
		"scopes":    c.cfg.Scopes,
	})
	if err != nil {
		return nil, err
	}
	var auth struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(resp.Data, &auth); err != nil {
		return nil, err
	}
	if auth.Code == "" {
		return nil, errors.New("discord authorize returned no code")
	}
	return c.exchangeCode(ctx, auth.Code)
}

func (c *Client) exchangeCode(ctx context.Context, code string) (*token, error) {
	return c.oauth(ctx, url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {c.cfg.RedirectURI},
		"client_id":     {c.cfg.ClientID},
		"client_secret": {c.cfg.ClientSecret},
	})
}

func (c *Client) refresh(ctx context.Context, refresh string) (*token, error) {
	return c.oauth(ctx, url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {refresh},
		"client_id":     {c.cfg.ClientID},
		"client_secret": {c.cfg.ClientSecret},
	})
}

func (c *Client) oauth(ctx context.Context, form url.Values) (*token, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://discord.com/api/v10/oauth2/token", strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", "desk-agent-discord-rpc/0.1")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, fmt.Errorf("discord oauth failed: %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	var tok token
	if err := json.Unmarshal(body, &tok); err != nil {
		return nil, err
	}
	tok.ExpiresAt = time.Now().Unix() + tok.ExpiresIn - 60
	return &tok, nil
}

func (c *Client) rpc(ctx context.Context, conn net.Conn, cmd string, args map[string]any) (*rpcResponse, error) {
	start := time.Now()
	nonce := strconv.FormatInt(time.Now().UnixNano(), 36)
	if args == nil {
		args = map[string]any{}
	}
	req := map[string]any{
		"cmd":   cmd,
		"args":  args,
		"nonce": nonce,
	}
	if err := writePacket(ctx, conn, opFrame, req); err != nil {
		return nil, err
	}
	for {
		resp, err := readPacket(ctx, conn)
		if err != nil {
			return nil, err
		}
		if resp.Nonce != nonce && !(resp.Nonce == "" && resp.Cmd == cmd) {
			c.logger.Debug("discord rpc ignored frame",
				"waiting_cmd", cmd,
				"waiting_nonce", nonce,
				"frame_cmd", resp.Cmd,
				"frame_nonce", resp.Nonce,
				"frame_code", resp.Code,
			)
			continue
		}
		if resp.Code != 0 {
			return nil, fmt.Errorf("discord rpc %s failed: %d %s", cmd, resp.Code, resp.Msg)
		}
		c.logger.Debug("discord rpc command completed", "cmd", cmd, "duration", time.Since(start).String())
		return resp, nil
	}
}

func (c *Client) handshake(ctx context.Context, conn net.Conn) (*rpcResponse, error) {
	if err := writePacket(ctx, conn, opHandshake, map[string]any{
		"v":         1,
		"client_id": c.cfg.ClientID,
	}); err != nil {
		return nil, err
	}
	return readPacket(ctx, conn)
}

func (c *Client) connect(ctx context.Context) (net.Conn, error) {
	var last error
	for _, p := range ipcPaths() {
		conn, err := (&net.Dialer{}).DialContext(ctx, "unix", p)
		if err == nil {
			return conn, nil
		}
		last = err
	}
	if last == nil {
		last = errors.New("no discord ipc socket found")
	}
	return nil, last
}

func writePacket(ctx context.Context, conn net.Conn, op uint32, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetWriteDeadline(deadline)
	} else {
		_ = conn.SetWriteDeadline(time.Now().Add(30 * time.Second))
	}
	var header [8]byte
	binary.LittleEndian.PutUint32(header[0:4], op)
	binary.LittleEndian.PutUint32(header[4:8], uint32(len(data)))
	_, err = conn.Write(append(header[:], data...))
	return err
}

func readPacket(ctx context.Context, conn net.Conn) (*rpcResponse, error) {
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetReadDeadline(deadline)
	} else {
		_ = conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	}
	var header [8]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return nil, err
	}
	size := binary.LittleEndian.Uint32(header[4:8])
	if size > 4<<20 {
		return nil, fmt.Errorf("discord rpc packet too large: %d", size)
	}
	buf := bytes.NewBuffer(make([]byte, 0, size))
	if _, err := io.CopyN(buf, conn, int64(size)); err != nil {
		return nil, err
	}
	var resp rpcResponse
	if err := json.Unmarshal(buf.Bytes(), &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (c *Client) loadToken() (*token, error) {
	data, err := os.ReadFile(c.cfg.TokenCache)
	if err != nil {
		return nil, err
	}
	var tok token
	if err := json.Unmarshal(data, &tok); err != nil {
		return nil, err
	}
	return &tok, nil
}

func (c *Client) saveToken(tok *token) error {
	if err := os.MkdirAll(filepath.Dir(c.cfg.TokenCache), 0o700); err != nil {
		return err
	}
	tmp := c.cfg.TokenCache + ".tmp"
	data, err := json.Marshal(tok)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, c.cfg.TokenCache)
}

func (t *token) Valid() bool {
	return t != nil && t.AccessToken != "" && t.ExpiresAt > time.Now().Unix()
}

func ipcPaths() []string {
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = filepath.Join("/run/user", strconv.Itoa(os.Getuid()))
	}
	var out []string
	for i := 0; i < 10; i++ {
		out = append(out, filepath.Join(runtimeDir, fmt.Sprintf("discord-ipc-%d", i)))
	}
	return out
}

func defaultTokenCache() (string, error) {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "desk-agent", "discord-rpc-token.json"), nil
}

func getenvDefault(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
