package main

import (
	"context"
	"fmt"
	"net/netip"
	"path/filepath"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type trafficProcessIdentity struct {
	Name string
	Path string
}

type trafficProcessSource struct {
	Network string
	Address netip.AddrPort
	Inbound netip.AddrPort
}

func trafficSourceFor(info *statistic.TrackerInfo) trafficProcessSource {
	metadata := info.Metadata
	var inbound netip.AddrPort
	if metadata.InIP.IsValid() {
		inbound = netip.AddrPortFrom(metadata.InIP.Unmap(), metadata.InPort)
	}
	var address netip.AddrPort
	if metadata.SrcIP.IsValid() {
		address = netip.AddrPortFrom(metadata.SrcIP.Unmap(), metadata.SrcPort)
	}
	return trafficProcessSource{metadata.NetWork.String(), address, inbound}
}

func (source trafficProcessSource) description() string {
	if !source.Address.IsValid() {
		return ""
	}
	return fmt.Sprintf("source://%s/%s?inbound=%d", source.Network, source.Address, source.Inbound.Port())
}

type trafficProcessKey struct {
	Tracker string
	Source  trafficProcessSource
}

type trafficProcessEntry struct {
	Identity    trafficProcessIdentity
	Created     time.Time
	LastSeen    time.Time
	Attempts    int
	LastAttempt time.Time
}

type nativeTrafficLookup func(trafficProcessSource) (trafficProcessIdentity, error)
type wslTrafficLookup func(context.Context) (map[trafficProcessSource]trafficProcessIdentity, error)

type trafficProcessResolver struct {
	mu      sync.Mutex
	entries map[trafficProcessKey]*trafficProcessEntry
	native  nativeTrafficLookup
	wsl     wslTrafficLookup
	lastWSL time.Time
	wake    chan struct{}
	start   sync.Once
	context context.Context
	cancel  context.CancelFunc
}

func newTrafficProcessResolver(native nativeTrafficLookup, wsl wslTrafficLookup) *trafficProcessResolver {
	ctx, cancel := context.WithCancel(context.Background())
	return &trafficProcessResolver{
		entries: make(map[trafficProcessKey]*trafficProcessEntry),
		native:  native, wsl: wsl, wake: make(chan struct{}, 1), context: ctx, cancel: cancel,
	}
}

func lookupNativeTrafficProcess(source trafficProcessSource) (trafficProcessIdentity, error) {
	_, path, err := process.FindProcessName(source.Network, source.Address.Addr(), int(source.Address.Port()))
	if err != nil {
		return trafficProcessIdentity{}, err
	}
	return trafficProcessIdentity{filepath.Base(path), path}, nil
}

func (resolver *trafficProcessResolver) lookup(key trafficProcessKey, now time.Time, submit bool) (trafficProcessIdentity, bool) {
	if !key.Source.Address.IsValid() || key.Source.Address.Port() == 0 {
		return trafficProcessIdentity{}, false
	}
	resolver.mu.Lock()
	entry := resolver.entries[key]
	if entry == nil && submit && len(resolver.entries) < 4096 {
		entry = &trafficProcessEntry{Created: now, LastSeen: now}
		resolver.entries[key] = entry
	}
	if entry == nil {
		resolver.mu.Unlock()
		return trafficProcessIdentity{}, false
	}
	if submit {
		entry.LastSeen = now
	}
	identity := entry.Identity
	pending := identity.Path == "" && now.Sub(entry.Created) < 10*time.Second
	resolver.mu.Unlock()
	if submit && pending {
		resolver.start.Do(func() { go resolver.run() })
		select {
		case resolver.wake <- struct{}{}:
		default:
		}
	}
	return identity, pending
}

func (resolver *trafficProcessResolver) run() {
	timer := time.NewTicker(200 * time.Millisecond)
	defer timer.Stop()
	for {
		select {
		case <-resolver.context.Done():
			return
		case <-resolver.wake:
		case <-timer.C:
		}
		resolver.refresh(time.Now())
	}
}

func (resolver *trafficProcessResolver) refresh(now time.Time) {
	if tunnel.FindProcessMode() == process.FindProcessOff {
		return
	}
	resolver.mu.Lock()
	requests := make(map[trafficProcessKey]int)
	for key, entry := range resolver.entries {
		if now.Sub(entry.LastSeen) > 2*time.Minute {
			delete(resolver.entries, key)
			continue
		}
		if entry.Identity.Path == "" && now.Sub(entry.Created) < 10*time.Second && now.Sub(entry.LastAttempt) >= 200*time.Millisecond && len(requests) < 256 {
			requests[key] = entry.Attempts
			entry.Attempts++
			entry.LastAttempt = now
		}
	}
	resolver.mu.Unlock()
	if len(requests) == 0 {
		return
	}
	unresolved := make(map[trafficProcessKey]struct{})
	for key, attempts := range requests {
		if resolver.context.Err() != nil {
			return
		}
		if resolver.native != nil && attempts < 3 {
			if identity, err := resolver.native(key.Source); err == nil && identity.Path != "" {
				resolver.assign(key, identity)
				continue
			}
		}
		unresolved[key] = struct{}{}
	}
	if len(unresolved) == 0 || resolver.wsl == nil || now.Sub(resolver.lastWSL) < time.Second {
		return
	}
	resolver.lastWSL = now
	ctx, cancel := context.WithTimeout(resolver.context, 3*time.Second)
	defer cancel()
	identities, err := resolver.wsl(ctx)
	if err != nil {
		return
	}
	for key := range unresolved {
		var match trafficProcessIdentity
		ambiguous := false
		for source, identity := range identities {
			if source.Network != key.Source.Network || source.Address.Port() != key.Source.Address.Port() {
				continue
			}
			if source.Address.Addr() != key.Source.Address.Addr() && !(source.Network == "udp" && source.Address.Addr().IsUnspecified() && source.Address.Addr().Is4() == key.Source.Address.Addr().Is4()) {
				continue
			}
			if key.Source.Inbound.Port() != 0 && source.Inbound.Port() != 0 && key.Source.Inbound.Port() != source.Inbound.Port() {
				continue
			}
			if key.Source.Inbound.IsValid() && source.Inbound.IsValid() && !key.Source.Inbound.Addr().IsUnspecified() && !source.Inbound.Addr().IsUnspecified() && key.Source.Inbound.Addr() != source.Inbound.Addr() {
				continue
			}
			if match.Path != "" && match != identity {
				ambiguous = true
				break
			}
			match = identity
		}
		if !ambiguous && match.Path != "" {
			resolver.assign(key, match)
		}
	}
}

func (resolver *trafficProcessResolver) assign(key trafficProcessKey, identity trafficProcessIdentity) {
	resolver.mu.Lock()
	defer resolver.mu.Unlock()
	if entry := resolver.entries[key]; entry != nil {
		entry.Identity = identity
	}
}
