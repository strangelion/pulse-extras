package main

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestRecoveryInspectionDoesNotDelete(t *testing.T){
	root:=t.TempDir()
	path:=filepath.Join(root,".pulse-share-example.part")
	if err:=os.WriteFile(path,[]byte("preserve"),0600);err!=nil{t.Fatal(err)}
	if err:=inspectRecovery(root);err!=nil{t.Fatal(err)}
	got,err:=os.ReadFile(path)
	if err!=nil || string(got)!="preserve"{t.Fatalf("changed recovery candidate: %v",err)}
}

func TestPrivateDirectoryExclusive(t *testing.T){
	if runtime.GOOS!="windows"{t.Skip("Windows ACL creation")}
	root:=t.TempDir()
	path:=filepath.Join(root,"private")
	if err:=createPrivateDirectory(path);err!=nil{t.Fatal(err)}
	if err:=createPrivateDirectory(path);err==nil{t.Fatal("existing directory accepted")}
	marker:=filepath.Join(path,"marker")
	if err:=os.WriteFile(marker,[]byte("safe"),0600);err!=nil{t.Fatal(err)}
	if err:=createPrivateDirectory(path);err==nil{t.Fatal("existing directory accepted")}
	if got,err:=os.ReadFile(marker);err!=nil || string(got)!="safe"{t.Fatal("existing content changed")}
}

func TestProgressWriter(t *testing.T){
	var dest bytes.Buffer
	var calls [][2]uint64
	p:=progressWriter{w:&dest,total:6,report:func(done,total uint64){calls=append(calls,[2]uint64{done,total})}}
	if _,err:=p.Write([]byte("abc"));err!=nil{t.Fatal(err)}
	if _,err:=p.Write([]byte("def"));err!=nil{t.Fatal(err)}
	if dest.String()!="abcdef" || len(calls)!=2 || calls[0]!=[2]uint64{3,6} || calls[1]!=[2]uint64{6,6}{t.Fatalf("progress %v",calls)}
}
