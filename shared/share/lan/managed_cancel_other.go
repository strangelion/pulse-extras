//go:build !windows

package main

import (
	"context"
	"errors"
)

func managedContext(parent context.Context, args []string) (context.Context, []string, func(), error) {
	if len(args)>0 && args[0]=="--managed-cancel-handle" {
		return parent,nil,func(){},errors.New("managed host cancellation requires Windows")
	}
	return parent,args,func(){},nil
}
