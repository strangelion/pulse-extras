package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"pulse-extras/share-lan/sharecore"
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
		if strings.HasPrefix(name,"share-v2-")&&entry.IsDir(){
			path:=filepath.Join(root,name)
			if _,err:=sharecore.LocalStageID(path);err==nil{
				state:="resume candidate"
				if _,err:=os.Lstat(filepath.Join(path,"publish.v2"));!os.IsNotExist(err){state="publication uncertain; inspect destination"}
				if _,err:=os.Lstat(filepath.Join(path,"published.v2"));err==nil{state="published; never replay"}
				fmt.Printf("RECOVERY BATCH %q %s\n",path,state);count++
			}
			continue
		}
		if strings.HasPrefix(name,"pulse-share-") || strings.HasPrefix(name,".pulse-share-") && strings.HasSuffix(name,".part"){
			fmt.Printf("RECOVERY CANDIDATE %q (ownership and liveness unverified)\n",name)
			if entry.IsDir() && strings.HasPrefix(name,"pulse-share-"){
				record,err:=readJournal(filepath.Join(root,name))
				if err!=nil{
					fmt.Println("RECOVERY PHASE unknown — missing or invalid journal")
				}else{
					fmt.Printf("RECOVERY PHASE %s name=%q bytes=%d sha256=%x\n",record.phase,record.offer.name,record.offer.size,record.offer.digest)
					if record.phase=="committing" || record.phase=="committed"{
						fmt.Println("RECOVERY ACTION check destination; do not retry automatically")
					}
				}
			}
			count++
		}
	}
	fmt.Printf("RECOVERY CANDIDATES %d — inspect only; no files removed\n",count)
	return nil
}
