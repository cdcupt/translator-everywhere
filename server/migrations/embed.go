// Package migrations embeds the ordered goose SQL migration files so they ship
// inside the static binary and run on boot.
package migrations

import "embed"

// FS holds the embedded migration files.
//
//go:embed *.sql
var FS embed.FS
