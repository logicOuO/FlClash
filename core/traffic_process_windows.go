package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/windows"
)

func platformTrafficProcessResolver() *trafficProcessResolver {
	return newTrafficProcessResolver(lookupNativeTrafficProcess, func(ctx context.Context) (map[trafficProcessSource]trafficProcessIdentity, error) {
		return scanWSLTrafficProcesses(ctx, runWSLTrafficCommand)
	})
}

func runWSLTrafficCommand(ctx context.Context, arguments ...string) ([]byte, error) {
	token, err := trafficWSLPeerToken()
	if err != nil {
		return nil, err
	}
	if token != 0 {
		defer token.Close()
	}
	command := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "wsl.exe"), arguments...)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000, Token: syscall.Token(token)}
	if token != 0 {
		command.Env, err = token.Environ(false)
		if err != nil {
			return nil, err
		}
	}
	return command.Output()
}

func trafficWSLPeerToken() (windows.Token, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return 0, err
	}
	if !user.User.Sid.IsWellKnown(windows.WinLocalSystemSid) {
		return 0, nil
	}
	connMu.Lock()
	defer connMu.Unlock()
	pipe, ok := conn.(interface{ Fd() uintptr })
	if !ok {
		return 0, fmt.Errorf("WSL lookup requires the connected UI process")
	}
	var peerPID uint32
	if err := windows.GetNamedPipeServerProcessId(windows.Handle(pipe.Fd()), &peerPID); err != nil {
		return 0, err
	}
	peer, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, peerPID)
	if err != nil {
		return 0, err
	}
	defer windows.CloseHandle(peer)
	var original windows.Token
	if err := windows.OpenProcessToken(peer, windows.TOKEN_QUERY|windows.TOKEN_DUPLICATE, &original); err != nil {
		return 0, err
	}
	defer original.Close()
	var token windows.Token
	err = windows.DuplicateTokenEx(original, windows.TOKEN_ASSIGN_PRIMARY|windows.TOKEN_QUERY|windows.TOKEN_DUPLICATE, nil, windows.SecurityImpersonation, windows.TokenPrimary, &token)
	return token, err
}
