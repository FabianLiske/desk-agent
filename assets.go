// Package assets holds the embedded action scripts.
//
// It lives in the module root so //go:embed can reach the top-level
// actions/ directory. The public API is intentionally tiny: consumers
// (internal/embedded) copy the files out to a writable location before
// executing them.
package assets

import "embed"

//go:embed all:actions
var Actions embed.FS
