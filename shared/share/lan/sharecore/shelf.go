package sharecore

import (
	"context"
	"errors"
)

// ShelfAdapter is a reserved host integration boundary, not a filesystem
// fallback. Implement only when Pulse publishes a compatible SDK interface.
var ErrShelfUnavailable = errors.New("Pulse Tray Shelf SDK interface unavailable")

type ShelfAdapter interface {
	// Snapshot must return a locally approved, immutable snapshot reference.
	Snapshot(context.Context)(ShelfSnapshot,error)
	// Insert accepts verified, already published local files only.
	// The host must copy or retain ownership before acknowledging success.
	Insert(context.Context,[]string)error
}
type ShelfSnapshot struct {
	Revision string
	Paths []string
}

type UnavailableShelf struct{}
func(UnavailableShelf) Snapshot(context.Context)(ShelfSnapshot,error){return ShelfSnapshot{},ErrShelfUnavailable}
func(UnavailableShelf) Insert(context.Context,[]string)error{return ErrShelfUnavailable}
