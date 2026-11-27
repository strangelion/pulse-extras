//go:build !windows

package main
import (
	"errors"
	"pulse-extras/share-lan/sharecore"
)
func readLocalClipboard(string)(clipboardPayload,error){return clipboardPayload{},errors.New("clipboard requires Windows")}
func localClipboardSequence()(uint32,error){return 0,errors.New("clipboard requires Windows")}
func writeLocalClipboard(sharecore.ContentKind,[]byte,[]string,uint32)error{return errors.New("clipboard requires Windows")}
