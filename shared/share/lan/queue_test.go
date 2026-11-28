package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestQueueRecordAndCrashState(t *testing.T){
	id:="00000000000000000001-0123456789abcdef01234567"
	j:=queuedBatch{Version:1,ID:id,Bind:"127.0.0.1",Endpoint:"127.0.0.1:45843",Label:"peer",Sources:"C:\\data",Channels:3}
	j.Local[0]=1;j.Peer[0]=2;j.Manifest[0]=3
	b,err:=json.Marshal(j);if err!=nil{t.Fatal(err)}
	if got,err:=decodeQueuedBatch(b,id);err!=nil||got!=j{t.Fatal(got,err)}
	if _,err:=decodeQueuedBatch(b,"../outside");err==nil{t.Fatal("invalid id admitted")}
	root:=t.TempDir()
	dir:=filepath.Join(root,id);if err=os.Mkdir(dir,0700);err!=nil{t.Fatal(err)}
	if ids,err:=queueIDs(root);err!=nil||len(ids)!=1||ids[0]!=id{t.Fatal(ids,err)}
	if state,err:=queueState(dir);err!=nil||state!="pending"{t.Fatal(state,err)}
	if err=markQueue(dir,"started");err!=nil{t.Fatal(err)}
	if state,err:=queueState(dir);err!=nil||state!="uncertain"{t.Fatal(state,err)}
	if err=markQueue(dir,"completed");err!=nil{t.Fatal(err)}
	if state,err:=queueState(dir);err!=nil||state!="completed"{t.Fatal(state,err)}
	if err=markQueue(dir,"completed");err==nil{t.Fatal("marker overwritten")}
}
