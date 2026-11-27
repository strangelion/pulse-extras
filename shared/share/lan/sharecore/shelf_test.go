package sharecore

import (
	"context"
	"errors"
	"testing"
)
func TestShelfUnavailable(t *testing.T){
	var shelf ShelfAdapter=UnavailableShelf{}
	if _,err:=shelf.Snapshot(context.Background());!errors.Is(err,ErrShelfUnavailable){t.Fatal(err)}
	if err:=shelf.Insert(context.Background(),[]string{"local-file"});!errors.Is(err,ErrShelfUnavailable){t.Fatal(err)}
}
