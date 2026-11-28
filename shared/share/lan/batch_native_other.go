//go:build !windows

package main

import (
	"context"
	"errors"
	"pulse-extras/share-lan/sharecore"
)

func acquireTransferOwner()(func(),error){return func(){},nil}
func auditBatchSource(string)error{return nil}
func publishBatch(context.Context,*sharecore.Stage,sharecore.Manifest,sharecore.ContentKind,nativeCommit,string,uint32)error{
	return errors.New("native batch publication requires Windows")
}
