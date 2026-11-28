//go:build windows

package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"unsafe"
)

func TestPrivateDirectoryDOSAlias(t *testing.T){
	root:=t.TempDir()
	long:=filepath.Join(root,"ordinary long directory name")
	if err:=os.Mkdir(long,0700);err!=nil{t.Fatal(err)}
	canonical,err:=plainDirectoryPath(long)
	if err!=nil{t.Fatal(err)}
	a,err:=os.Stat(canonical)
	if err!=nil{t.Fatal(err)}
	b,err:=os.Stat(long)
	if err!=nil || !os.SameFile(a,b){t.Fatal("normalization changed identity",err)}
	// 8.3 aliases are optional on NTFS. Verify when the volume provides one.
	proc:=kernel32.NewProc("GetShortPathNameW")
	w,err:=syscall.UTF16PtrFromString(long)
	if err!=nil{t.Fatal(err)}
	var buf [32768]uint16
	n,_,_:=proc.Call(uintptr(unsafe.Pointer(w)),uintptr(unsafe.Pointer(&buf[0])),uintptr(len(buf)))
	if n==0 || n>=uintptr(len(buf)){t.Skip("short DOS alias unavailable")}
	short:=syscall.UTF16ToString(buf[:n])
	if equalLocalPath(short,long){t.Skip("volume does not supply a distinct DOS alias")}
	child:=filepath.Join(short,"private")
	if err:=createPrivateDirectory(child);err!=nil{t.Fatal(err)}
	if err:=auditPrivateDirectory(filepath.Join(long,"private"));err!=nil{t.Fatal(err)}
}

func TestPrivateDirectoryRejectsReparseAncestor(t *testing.T){
	root:=t.TempDir()
	real:=filepath.Join(root,"real")
	if err:=os.Mkdir(real,0700);err!=nil{t.Fatal(err)}
	link:=filepath.Join(root,"link")
	if err:=os.Symlink(real,link);err!=nil{t.Skipf("directory symlink unavailable: %v",err)}
	if err:=createPrivateDirectory(filepath.Join(link,"private"));err==nil{t.Fatal("accepted reparse ancestor")}
	if _,err:=os.Stat(filepath.Join(real,"private"));!os.IsNotExist(err){t.Fatal("unexpected target creation",err)}
}
