package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func equalLocalPath(a,b string) bool {
	return strings.EqualFold(filepath.Clean(a),filepath.Clean(b))
}

// Recovery inventory is deliberately read-only. Names are hints, not
// proof of ownership or liveness; never automatically delete by pattern.
func inspectRecovery(path string) error {
	root,err:=storeRoot(path)
	if err!=nil{return err}
	dir,err:=os.Open(root)
	if err!=nil{return err}
	defer dir.Close()
	entries,err:=dir.ReadDir(1025)
	if err!=nil && err!=io.EOF{return err}
	if len(entries)>1024{return errors.New("recovery inventory exceeds 1024 entries")}
	count:=0
	for _,entry:=range entries{
		name:=entry.Name()
		if strings.HasPrefix(name,"pulse-share-") || strings.HasPrefix(name,".pulse-share-") && strings.HasSuffix(name,".part"){
			fmt.Printf("RECOVERY CANDIDATE %q (ownership and liveness unverified)\n",name)
			count++
		}
	}
	fmt.Printf("RECOVERY CANDIDATES %d — inspect only; no files removed\n",count)
	return nil
}
