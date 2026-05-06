// Shared state-dir resolution + flock primitives used by note/task/focus.
//
// Mirrors lib/state/{profile,lock}.sh resolution order:
//   profile  := JARVIS_PROFILE | "default"
//   home     := JARVIS_HOME | $XDG_DATA_HOME/jarvis | $HOME/.local/share/jarvis
//   profileDir := home/profile

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

func profileDir() (string, error) {
	home := os.Getenv("JARVIS_HOME")
	if home == "" {
		if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
			home = filepath.Join(xdg, "jarvis")
		} else {
			h, err := os.UserHomeDir()
			if err != nil {
				return "", fmt.Errorf("resolve home: %w", err)
			}
			home = filepath.Join(h, ".local", "share", "jarvis")
		}
	}
	prof := os.Getenv("JARVIS_PROFILE")
	if prof == "" {
		prof = "default"
	}
	return filepath.Join(home, prof), nil
}

// withFlock acquires an exclusive flock on `path` (creating it if needed)
// for the duration of `body`. Mirrors lib/state/lock.sh::state_with_lock.
//
// The lock sidecar is `<path>.lock` so the lock survives even when the
// target is replaced via tmp+rename mid-mutation.
func withFlock(path string, body func() error) (err error) {
	lockPath := path + ".lock"
	if mkErr := os.MkdirAll(filepath.Dir(lockPath), 0o755); mkErr != nil {
		return fmt.Errorf("mkdir for lock %s: %w", lockPath, mkErr)
	}
	f, openErr := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if openErr != nil {
		return fmt.Errorf("open lock %s: %w", lockPath, openErr)
	}
	defer func() {
		if cErr := f.Close(); cErr != nil && err == nil {
			err = fmt.Errorf("close lock: %w", cErr)
		}
	}()
	if flErr := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); flErr != nil {
		return fmt.Errorf("flock %s: %w", lockPath, flErr)
	}
	defer func() {
		if uErr := syscall.Flock(int(f.Fd()), syscall.LOCK_UN); uErr != nil && err == nil {
			err = fmt.Errorf("flock unlock: %w", uErr)
		}
	}()
	return body()
}
