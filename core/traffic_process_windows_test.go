package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
)

var trafficWSLServicePipe = flag.String("traffic-wsl-service-pipe", "", "named pipe for opt-in SYSTEM attribution test")
var trafficWSLServiceResult = flag.String("traffic-wsl-service-result", "", "result file for opt-in SYSTEM attribution test")

func TestTrafficWSLServiceWorker(t *testing.T) {
	if *trafficWSLServicePipe == "" || *trafficWSLServiceResult == "" {
		t.Skip("requires isolated SYSTEM task and user-owned named pipe")
	}
	result := "FAILED: worker did not finish"
	defer func() { _ = os.WriteFile(*trafficWSLServiceResult, []byte(result), 0600) }()
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil || !user.User.Sid.IsWellKnown(windows.WinLocalSystemSid) {
		result = "FAILED: worker is not SYSTEM"
		t.Fatal(result)
	}
	timeout := 10 * time.Second
	pipe, err := winio.DialPipe(*trafficWSLServicePipe, &timeout)
	if err != nil {
		result = fmt.Sprintf("FAILED: dial user pipe: %v", err)
		t.Fatal(result)
	}
	defer pipe.Close()
	connMu.Lock()
	conn = pipe
	connMu.Unlock()
	defer func() {
		connMu.Lock()
		conn = nil
		connMu.Unlock()
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	identities, err := scanWSLTrafficProcesses(ctx, runWSLTrafficCommand)
	if err != nil {
		result = fmt.Sprintf("FAILED: scan WSL as UI user: %v", err)
		t.Fatal(result)
	}
	for source, identity := range identities {
		if identity.Name == "codex" && source.Inbound.Port() == 7897 && strings.HasPrefix(identity.Path, "wsl://Ubuntu-20.04/") {
			result = fmt.Sprintf("PASS: SYSTEM Core resolved %s to %s using named-pipe UI owner", source.Address, identity.Path)
			t.Log(result)
			return
		}
	}
	result = fmt.Sprintf("FAILED: SYSTEM Core found no expected WSL proxy socket (%d identities)", len(identities))
	t.Fatal(result)
}
