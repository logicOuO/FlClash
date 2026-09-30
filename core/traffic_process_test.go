package main

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"runtime"
	"strings"
	"testing"
	"time"

	P "github.com/metacubex/mihomo/component/process"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func testTrafficSource() trafficProcessSource {
	return trafficProcessSource{"tcp", netip.MustParseAddrPort("127.0.0.1:43933"), netip.MustParseAddrPort("127.0.0.1:7897")}
}

func TestTrafficWSLParsing(t *testing.T) {
	output := "TCP\nESTAB 0 0 127.0.0.1:43933 127.0.0.1:7897 users:((\"codex\",pid=865051,fd=12))\n" +
		"ESTAB 0 0 [::ffff:127.0.0.1]:43934 [::ffff:127.0.0.1]:7897 users:((\"codex\",pid=865051,fd=13))\n" +
		"ESTAB 0 0 127.0.0.1:43935 127.0.0.1:7897 users:((\"a\",pid=1,fd=1),(\"b\",pid=2,fd=2))\n" +
		"UDP\nUNCONN 0 0 127.0.0.1:43936 0.0.0.0:* users:((\"codex\",pid=865051,fd=14))\nPATHS\n" +
		"865051\t/home/keye/CaseSensitive/codex\n1\t/opt/a\n2\t/opt/b\n"
	identities := parseWSLTrafficProcesses("Ubuntu-20.04", output)
	if len(identities) != 3 || identities[testTrafficSource()].Path != "wsl://Ubuntu-20.04/home/keye/CaseSensitive/codex" {
		t.Fatalf("unexpected socket identities: %+v", identities)
	}
	for _, value := range []string{"127.0.0.1:65536", "invalid:1", "no-port"} {
		if _, err := parseTrafficSocketAddress(value); err == nil {
			t.Fatalf("accepted invalid socket %q", value)
		}
	}
}

func TestTrafficWSLAllRunningDistributionsAndAmbiguity(t *testing.T) {
	var distributions []string
	command := func(_ context.Context, arguments ...string) ([]byte, error) {
		if arguments[0] == "--list" {
			return []byte("Ubuntu-24.04\nUbuntu-20.04\n"), nil
		}
		distributions = append(distributions, arguments[1])
		if arguments[1] == "Ubuntu-24.04" {
			return []byte("TCP\nESTAB 0 0 127.0.0.1:43933 127.0.0.1:7897\nPATHS\n"), nil
		}
		return []byte("TCP\nESTAB 0 0 127.0.0.1:43933 127.0.0.1:7897 users:((\"codex\",pid=42,fd=12))\nPATHS\n42\t/opt/codex\n"), nil
	}
	identities, err := scanWSLTrafficProcesses(context.Background(), command)
	if err != nil || len(distributions) != 2 || identities[testTrafficSource()].Name != "codex" {
		t.Fatalf("did not search the owning distro: %+v %v", identities, err)
	}
	conflicting := func(_ context.Context, arguments ...string) ([]byte, error) {
		if arguments[0] == "--list" {
			return []byte("A\nB\n"), nil
		}
		return []byte("TCP\nESTAB 0 0 127.0.0.1:43933 127.0.0.1:7897 users:((\"codex\",pid=42,fd=12))\nPATHS\n42\t/opt/codex\n"), nil
	}
	identities, _ = scanWSLTrafficProcesses(context.Background(), conflicting)
	if len(identities) != 0 {
		t.Fatal("ambiguous socket was guessed")
	}
	names := decodeWSLDistributionList([]byte{'U', 0, 'b', 0, '\r', 0, '\n', 0})
	if len(names) != 1 || names[0] != "Ub" {
		t.Fatal(names)
	}
}

func TestTrafficProcessRetryAndConnectionIdentity(t *testing.T) {
	attempts := 0
	resolver := newTrafficProcessResolver(func(trafficProcessSource) (trafficProcessIdentity, error) {
		attempts++
		if attempts < 2 {
			return trafficProcessIdentity{}, errors.New("not yet visible")
		}
		return trafficProcessIdentity{"app", "/opt/app"}, nil
	}, nil)
	defer resolver.cancel()
	now := time.Now()
	key := trafficProcessKey{"first", testTrafficSource()}
	resolver.entries[key] = &trafficProcessEntry{Created: now, LastSeen: now}
	resolver.refresh(now)
	resolver.refresh(now.Add(time.Millisecond))
	resolver.refresh(now.Add(250 * time.Millisecond))
	identity, pending := resolver.lookup(key, now, false)
	if attempts != 2 || pending || identity.Path != "/opt/app" {
		t.Fatalf("retry did not resolve: %d %+v %v", attempts, identity, pending)
	}
	if identity, _ := resolver.lookup(trafficProcessKey{"new", key.Source}, now, false); identity.Path != "" {
		t.Fatal("reused source port inherited previous connection identity")
	}
}

func TestTrafficProcessWSLMatchesSocketAndRejectsConflicts(t *testing.T) {
	now := time.Now()
	identity := trafficProcessIdentity{"codex", "wsl://Ubuntu-20.04/opt/codex"}
	for _, conflict := range []bool{false, true} {
		source := testTrafficSource()
		source.Network = "udp"
		wildcard := source
		wildcard.Address = netip.MustParseAddrPort("0.0.0.0:43933")
		wildcard.Inbound = netip.AddrPort{}
		resolver := newTrafficProcessResolver(nil, func(context.Context) (map[trafficProcessSource]trafficProcessIdentity, error) {
			identities := map[trafficProcessSource]trafficProcessIdentity{wildcard: identity}
			if conflict {
				identities[source] = trafficProcessIdentity{"other", "wsl://Other/other"}
			}
			return identities, nil
		})
		defer resolver.cancel()
		key := trafficProcessKey{"socket", source}
		resolver.entries[key] = &trafficProcessEntry{Created: now, LastSeen: now}
		wrongPeer := trafficProcessKey{"wrongPeer", testTrafficSource()}
		wrongPeer.Source.Inbound = netip.MustParseAddrPort("127.0.0.1:7898")
		resolver.entries[wrongPeer] = &trafficProcessEntry{Created: now, LastSeen: now}
		resolver.refresh(now)
		resolved, _ := resolver.lookup(key, now, false)
		if conflict && resolved.Path != "" || !conflict && resolved != identity {
			t.Fatalf("unexpected wildcard attribution, conflict=%v: %+v", conflict, resolved)
		}
		if resolved, _ := resolver.lookup(wrongPeer, now, false); resolved.Path != "" {
			t.Fatal("different protocol/peer was matched")
		}
	}
}

func TestTrafficHistoryDeferredIdentityAndForcedFlush(t *testing.T) {
	resolver := newTrafficProcessResolver(nil, nil)
	resolver.start.Do(func() {})
	defer resolver.cancel()
	collector := newTrafficHistoryCollector()
	collector.resolver = resolver
	info := historyInfo("", true)
	info.Metadata.Process = ""
	info.Metadata.SrcIP = netip.MustParseAddr("127.0.0.1")
	info.Metadata.SrcPort = 43933
	info.Metadata.InIP = netip.MustParseAddr("127.0.0.1")
	info.Metadata.InPort = 7897
	now := time.Now()
	collector.record(info, 100, 200, now)
	if batch := collector.read(trafficHistoryAck{}); len(batch.Records) != 0 {
		t.Fatal("unresolved traffic published before lookup window")
	}
	key := trafficProcessKey{info.UUID.String(), trafficSourceFor(info)}
	resolver.assign(key, trafficProcessIdentity{"codex", "wsl://Ubuntu-20.04/Case/codex"})
	batch := collector.read(trafficHistoryAck{})
	if len(batch.Records) != 1 || batch.Records[0].Upload != 100 || batch.Records[0].Download != 200 || batch.Records[0].Minute != now.Unix()/60*60 || batch.Records[0].ProcessPath != "wsl://Ubuntu-20.04/Case/codex" {
		t.Fatal(batch)
	}
	resolver.mu.Lock()
	delete(resolver.entries, key)
	resolver.mu.Unlock()
	collector.record(info, 3, 4, now)
	forced := collector.read(trafficHistoryAck{Session: batch.Session, Sequence: batch.Sequence, Flush: true})
	if len(forced.Records) != 1 || forced.Records[0].Upload != 3 || forced.Records[0].Download != 4 || !strings.HasPrefix(forced.Records[0].ProcessPath, "source://tcp/127.0.0.1:43933") {
		t.Fatal(forced)
	}
	if replay := collector.read(trafficHistoryAck{Flush: true}); replay.Sequence != forced.Sequence || replay.Records[0].Upload != 3 {
		t.Fatal("forced flush broke acknowledgment replay")
	}
}

func TestTrafficHistoryProcessOffDoesNotLookup(t *testing.T) {
	previous := tunnel.FindProcessMode()
	tunnel.SetFindProcessMode(P.FindProcessOff)
	defer tunnel.SetFindProcessMode(previous)
	resolver := newTrafficProcessResolver(nil, nil)
	defer resolver.cancel()
	collector := newTrafficHistoryCollector()
	collector.resolver = resolver
	info := historyInfo("", true)
	info.Metadata = &C.Metadata{SrcIP: netip.MustParseAddr("127.0.0.1"), SrcPort: 12345}
	collector.record(info, 10, 20, time.Now())
	if len(resolver.entries) != 0 || len(collector.read(trafficHistoryAck{}).Records) != 1 {
		t.Fatal("process-off mode performed process lookup or lost bytes")
	}
}

func TestTrafficHistoryAttributionExpiryAndCapacity(t *testing.T) {
	for _, capacity := range []bool{false, true} {
		resolver := newTrafficProcessResolver(nil, nil)
		resolver.start.Do(func() {})
		defer resolver.cancel()
		collector := newTrafficHistoryCollector()
		collector.resolver = resolver
		info := historyInfo("", true)
		info.Metadata.Process = ""
		info.Metadata.SrcIP = netip.MustParseAddr("127.0.0.1")
		info.Metadata.SrcPort = 43933
		if capacity {
			for index := 0; index < 4096; index++ {
				resolver.entries[trafficProcessKey{Tracker: fmt.Sprint(index)}] = &trafficProcessEntry{}
			}
		}
		collector.record(info, 11, 22, time.Now())
		if !capacity {
			for _, entry := range resolver.entries {
				entry.Created = time.Now().Add(-11 * time.Second)
			}
		}
		batch := collector.read(trafficHistoryAck{})
		if len(batch.Records) != 1 || batch.Records[0].Upload != 11 || batch.Records[0].Download != 22 || batch.DroppedBytes != 0 {
			t.Fatalf("fallback lost traffic, capacity=%v: %+v", capacity, batch)
		}
	}
}

func TestTrafficWSLLive(t *testing.T) {
	if runtime.GOOS != "windows" || os.Getenv("FLCLASH_TEST_WSL") != "1" {
		t.Skip("requires opt-in Windows host with active WSL proxy connections")
	}
	resolver := platformTrafficProcessResolver()
	defer resolver.cancel()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	identities, err := resolver.wsl(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for source, identity := range identities {
		if identity.Name == "codex" && source.Inbound.Port() == 7897 {
			key := trafficProcessKey{"live", source}
			now := time.Now()
			resolver.entries[key] = &trafficProcessEntry{Created: now, LastSeen: now}
			resolver.refresh(now)
			resolved, _ := resolver.lookup(key, now, false)
			if resolved != identity {
				t.Fatalf("live socket mismatch: %+v %+v", resolved, identity)
			}
			t.Logf("resolved %s to %s", source.Address, identity.Path)
			return
		}
	}
	t.Fatal("no live WSL codex proxy socket identified")
}
