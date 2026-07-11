// Package assets holds embedded runtime files.
//
// It lives in the module root so //go:embed can reach the top-level
// actions/ and configs/ directories. The public API is intentionally tiny:
// consumers (internal/embedded) copy files out to writable locations before
// using them.
package assets

import "embed"

//go:embed all:actions
var Actions embed.FS

//go:embed all:configs/displays
var DisplayConfigs embed.FS
