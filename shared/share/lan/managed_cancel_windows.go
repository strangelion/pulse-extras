//go:build windows

package main

import (
	"context"
	"errors"
	"strconv"
	"syscall"
	"time"
)

// The only inherited capability is a private cancellation event owned by
// the supervising Pulse task. Never accept a named endpoint or remote event.
func managedContext(parent context.Context, args []string) (context.Context, []string, func(), error) {
	if len(args) == 0 || args[0] != "--managed-cancel-handle" {
		return parent, args, func(){}, nil
	}
	if len(args) < 3 { return parent,nil,func(){},errors.New("missing managed cancellation event") }
	n, err := strconv.ParseUint(args[1],16,64)
	if err != nil || n == 0 || n == ^uint64(0) { return parent,nil,func(){},errors.New("invalid cancellation handle") }
	h := syscall.Handle(n)
	// The event is inherited, never opened by name. Prevent further inheritance.
	kernel := syscall.NewLazyDLL("kernel32.dll")
	setInfo := kernel.NewProc("SetHandleInformation")
	if ok,_,err := setInfo.Call(uintptr(h),1,0); ok == 0 { return parent,nil,func(){},err }
	ctx,cancel := context.WithCancel(parent)
	done := make(chan struct{})
	go func(){
		defer close(done)
		ticker := time.NewTicker(100*time.Millisecond)
		defer ticker.Stop()
		for {
			status,err := syscall.WaitForSingleObject(h,0)
			if err != nil || status != 258 { cancel(); return }
			select { case <-ctx.Done():return; case <-ticker.C: }
		}
	}()
	return ctx,args[2:],func(){cancel();<-done;syscall.CloseHandle(h)},nil
}
