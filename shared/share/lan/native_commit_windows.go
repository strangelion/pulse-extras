//go:build windows

package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"
	"unsafe"
)

var createEvent = kernel32.NewProc("CreateEventW")
var signalEvent = kernel32.NewProc("SetEvent")

func runNativeCommit(ctx context.Context, supervisor, worker, workerPin, source, destination, name, digest string) error {
	var sa syscall.SecurityAttributes
	sa.Length = uint32(unsafe.Sizeof(sa))
	sa.InheritHandle = 1
	raw,_,err:=createEvent.Call(uintptr(unsafe.Pointer(&sa)),1,0,0)
	if raw==0{return err}
	h:=syscall.Handle(raw)
	defer syscall.CloseHandle(h)
	cmd:=exec.CommandContext(ctx,supervisor,"--confirm-managed-copy",worker,workerPin,source,destination,name,digest,fmt.Sprintf("%x",raw))
	cmd.SysProcAttr=&syscall.SysProcAttr{AdditionalInheritedHandles:[]syscall.Handle{h},HideWindow:true}
	cmd.Stdout=io.Discard
	cmd.Stderr=os.Stderr
	cmd.Cancel=func()error{
		if ok,_,err:=signalEvent.Call(raw);ok==0{return err}
		return nil
	}
	cmd.WaitDelay=8*time.Second
	if err:=cmd.Run();err!=nil{return fmt.Errorf("native commit failed or uncertain: %w",err)}
	return nil
}
