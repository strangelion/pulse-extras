//go:build windows

package main

import "testing"

func TestManagedTransferOwner(t *testing.T){
	release,err:=acquireTransferOwner();if err!=nil{t.Fatal(err)}
	if second,err:=acquireTransferOwner();err==nil{second();release();t.Fatal("second managed owner admitted")}
	release()
	again,err:=acquireTransferOwner();if err!=nil{t.Fatal(err)}
	again()
}
