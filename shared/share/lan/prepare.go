package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func prepareDevice(ctx context.Context, store, spool string) error {
	store, spool = filepath.Clean(store), filepath.Clean(spool)
	if !filepath.IsAbs(store) || !filepath.IsAbs(spool) {
		return errors.New("choose absolute identity and spool directories")
	}
	foldStore, foldSpool := strings.ToLower(store), strings.ToLower(spool)
	if foldStore == foldSpool || strings.HasPrefix(foldStore, foldSpool+string(os.PathSeparator)) ||
		strings.HasPrefix(foldSpool, foldStore+string(os.PathSeparator)) {
		return errors.New("identity and spool require separate directories")
	}
	for _, path := range []string{store, spool} {
		if err := ctx.Err(); err != nil {
			return err
		}
		_, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			if err := createPrivateDirectory(path); err != nil && !errors.Is(err, os.ErrExist) {
				return err
			}
		} else if err != nil {
			return err
		}
		if err := auditPrivateDirectory(path); err != nil {
			return err
		}
	}
	storeInfo, err := os.Stat(store)
	if err != nil {
		return err
	}
	spoolInfo, err := os.Stat(spool)
	if err != nil {
		return err
	}
	if os.SameFile(storeInfo, spoolInfo) {
		return errors.New("identity and spool resolve to the same directory")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if _, err := os.Lstat(filepath.Join(store, identityFile)); errors.Is(err, os.ErrNotExist) {
		if _, err := initStoredIdentity(store); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
	} else if err != nil {
		return err
	}
	if _, err := loadStoredIdentity(store); err != nil {
		return err
	}
	fmt.Println("DEVICE_READY")
	return nil
}

func prepareDeviceCLI(ctx context.Context, args []string) error {
	flags := flags("device-prepare")
	store := flags.String("store", "", "explicit private identity directory")
	spool := flags.String("spool", "", "separate private spool directory")
	if err := noExtra(flags, args); err != nil {
		return err
	}
	return prepareDevice(ctx, *store, *spool)
}
