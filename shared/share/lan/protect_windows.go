//go:build windows

package main

import (
	"errors"
	"runtime"
	"syscall"
	"unsafe"
)

type dataBlob struct {
	size uint32
	data *byte
}

// DPAPI with current-user scope; no CRYPTPROTECT_LOCAL_MACHINE or UI.
// Windows system DLLs only. No key/passphrase is placed in arguments/logs.
var crypt32 = syscall.NewLazyDLL("crypt32.dll")
var kernel32 = syscall.NewLazyDLL("kernel32.dll")
var cryptProtect = crypt32.NewProc("CryptProtectData")
var cryptUnprotect = crypt32.NewProc("CryptUnprotectData")
var localFree = kernel32.NewProc("LocalFree")

func dpapi(input []byte, protect bool) ([]byte, error) {
	if len(input) == 0 || len(input) > storeLimit { return nil, errors.New("invalid DPAPI input") }
	in := dataBlob{uint32(len(input)), &input[0]}
	var out dataBlob
	proc := cryptUnprotect
	if protect { proc = cryptProtect }
	r, _, err := proc.Call(uintptr(unsafe.Pointer(&in)), 0, 0, 0, 0, 1, uintptr(unsafe.Pointer(&out)))
	runtime.KeepAlive(input)
	if out.data != nil {
		defer func() {
			if out.size <= storeLimit { clear(unsafe.Slice(out.data, int(out.size))) }
			localFree.Call(uintptr(unsafe.Pointer(out.data)))
		}()
	}
	if r == 0 { return nil, err }
	if out.data == nil || out.size == 0 || out.size > storeLimit { return nil, errors.New("invalid DPAPI output") }
	return append([]byte(nil), unsafe.Slice(out.data, int(out.size))...), nil
}

func protectIdentity(input []byte) ([]byte, error) { return dpapi(input, true) }
func unprotectIdentity(input []byte) ([]byte, error) { return dpapi(input, false) }
