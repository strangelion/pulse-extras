//go:build !windows

package main

import (
	"context"
	"errors"
)

func runNativeCommit(context.Context,string,string,string,string,string,string,string) error {
	return errors.New("native commit requires Windows")
}
