//go:build !windows

package main

import "errors"

func createPrivateDirectory(string) error {
	return errors.New("private directory creation requires Windows")
}

func auditPrivateDirectory(string)error{return errors.New("managed private-directory audit requires Windows")}
