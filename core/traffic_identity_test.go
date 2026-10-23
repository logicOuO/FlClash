package main

import (
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/process"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestAndroidTrafficIdentityPreservesPackageAndUser(t *testing.T) {
	collector := newTrafficHistoryCollector()
	for _, uid := range []uint32{10001, 1010001} {
		metadata := &C.Metadata{Process: "com.example.app", Uid: uid}
		info := &statistic.TrackerInfo{Metadata: metadata, Chain: C.Chain{"node"}}
		prepareAndroidTrafficIdentity(info)
		if metadata.ProcessPath != "" || info.Metadata.ProcessPath == "" {
			t.Fatal("tracker identity mutated shared connection metadata")
		}
		collector.record(info, 5, 6, time.Unix(60, 0))
		collector.record(info, 7, 8, time.Unix(61, 0))
	}
	batch := collector.read(trafficHistoryAck{})
	if len(batch.Records) != 2 {
		t.Fatalf("different Android users merged: %+v", batch)
	}
	for _, record := range batch.Records {
		if record.Upload != 12 || record.Download != 14 {
			t.Fatal(record)
		}
	}
}

func TestAndroidTrafficIdentityResolvesBeforeShortConnectionCloses(t *testing.T) {
	previousMode := tunnel.FindProcessMode()
	previousResolver := process.DefaultPackageNameResolver
	defer func() {
		tunnel.SetFindProcessMode(previousMode)
		process.DefaultPackageNameResolver = previousResolver
	}()
	tunnel.SetFindProcessMode(process.FindProcessStrict)
	lookups := 0
	process.DefaultPackageNameResolver = func(metadata *C.Metadata) (string, error) {
		lookups++
		metadata.Uid = 10042
		return "com.example.first,com.example.second", nil
	}
	info := &statistic.TrackerInfo{Metadata: &C.Metadata{}}
	prepareAndroidTrafficIdentity(info)
	if lookups != 1 || info.Metadata.Process != "com.example.first,com.example.second" || info.Metadata.ProcessPath == "" {
		t.Fatal(info.Metadata)
	}
	tunnel.SetFindProcessMode(process.FindProcessOff)
	info = &statistic.TrackerInfo{Metadata: &C.Metadata{Uid: 10042}}
	prepareAndroidTrafficIdentity(info)
	if lookups != 1 || info.Metadata.ProcessPath != "android-uid://10042" {
		t.Fatal("disabled lookup or UID fallback not respected")
	}
}

func TestAndroidSharedUIDStatisticsDoNotChangeRoutingIdentity(t *testing.T) {
	previous := trafficPackageNames.Load()
	defer trafficPackageNames.Store(previous)
	packages := "com.example.first,com.example.second"
	lookup := func(uid uint32) string { return packages }
	trafficPackageNames.Store(&lookup)
	metadata := &C.Metadata{Process: "com.example.first", Uid: 10042}
	info := &statistic.TrackerInfo{Metadata: metadata}
	prepareAndroidTrafficIdentity(info)
	if metadata.Process != "com.example.first" || info.Metadata.Process != packages {
		t.Fatal("statistics overwrote routing identity or guessed a shared UID owner")
	}
	packages = "com.example.second"
	info = &statistic.TrackerInfo{Metadata: metadata}
	prepareAndroidTrafficIdentity(info)
	if info.Metadata.Process != packages {
		t.Fatal("package membership change was not reflected")
	}
}
