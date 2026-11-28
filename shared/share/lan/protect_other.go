//go:build !windows

package main

import "errors"

func protectIdentity([]byte) ([]byte, error) { return nil, errors.New("persistent identity requires Windows DPAPI") }
func unprotectIdentity([]byte) ([]byte, error) { return nil, errors.New("persistent identity requires Windows DPAPI") }
