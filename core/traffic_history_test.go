package main

import (
	"encoding/json"
	"fmt"
	"net"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func historyInfo(processPath string, proxy bool) *statistic.TrackerInfo {
	chain := C.Chain{"DIRECT"}
	if proxy {
		chain = C.Chain{"node", "group"}
	}
	return &statistic.TrackerInfo{
		Metadata: &C.Metadata{Process: "browser", ProcessPath: processPath},
		Chain:    chain,
	}
}

func TestTrafficHistoryMinutesAndRouting(t *testing.T) {
	collector := newTrafficHistoryCollector()
	start := time.Unix(1800000000, 0)
	collector.record(historyInfo("/opt/browser", true), 10, 20, start)
	collector.record(historyInfo("/opt/browser", true), 5, 7, start.Add(time.Second))
	collector.record(historyInfo("/opt/browser", false), 1, 2, start)
	collector.record(historyInfo("/other/browser", true), 3, 4, start)
	collector.record(historyInfo("/opt/browser", true), 100, 200, start.Add(time.Minute))
	batch := collector.read(trafficHistoryAck{})
	if len(batch.Records) != 4 {
		t.Fatalf("expected separate paths, minutes and routes: %+v", batch)
	}
	var upload, download int64
	for _, record := range batch.Records {
		upload += record.Upload
		download += record.Download
	}
	if upload != 119 || download != 233 {
		t.Fatalf("unexpected totals %d/%d", upload, download)
	}
	data, err := json.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	first := decoded["records"].([]any)[0].(map[string]any)
	if _, exists := first["minute"]; !exists {
		t.Fatal("embedded key fields are missing from JSON")
	}
}

func TestTrafficHistoryAcknowledgmentReplay(t *testing.T) {
	collector := newTrafficHistoryCollector()
	info := historyInfo("/browser", true)
	collector.record(info, 10, 20, time.Now())
	first := collector.read(trafficHistoryAck{})
	collector.record(info, 3, 4, time.Now())
	for _, ack := range []trafficHistoryAck{{}, {Session: "other", Sequence: first.Sequence}, {Session: first.Session, Sequence: first.Sequence + 1}} {
		if got := collector.read(ack); !reflect.DeepEqual(got, first) {
			t.Fatal("unacknowledged batch changed")
		}
	}
	ack := trafficHistoryAck{Session: first.Session, Sequence: first.Sequence}
	second := collector.read(ack)
	if second.Sequence != first.Sequence+1 || second.Records[0].Upload != 3 {
		t.Fatalf("ack lost newly arrived traffic: %+v", second)
	}
	if got := collector.read(ack); !reflect.DeepEqual(got, second) {
		t.Fatal("old ack cleared newer batch")
	}
	empty := collector.read(trafficHistoryAck{Session: second.Session, Sequence: second.Sequence})
	if len(empty.Records) != 0 {
		t.Fatal("ack did not drain batch")
	}
}

func TestTrafficHistoryConcurrentRecording(t *testing.T) {
	collector := newTrafficHistoryCollector()
	info := historyInfo("/browser", true)
	var workers sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for sample := 0; sample < 1000; sample++ {
				collector.record(info, 1, 2, time.Unix(1800000000, 0))
			}
		}()
	}
	workers.Wait()
	batch := collector.read(trafficHistoryAck{})
	if batch.Records[0].Upload != 16000 || batch.Records[0].Download != 32000 {
		t.Fatal(batch)
	}
}

func TestTrafficHistoryBoundedBacklogAndBatch(t *testing.T) {
	collector := newTrafficHistoryCollector()
	for index := 0; index < 65537; index++ {
		collector.record(historyInfo(fmt.Sprintf("/app/%d", index), true), 1, 2, time.Unix(1800000000, 0))
	}
	if len(collector.records) != 65536 {
		t.Fatal("backlog was not bounded")
	}
	batch := collector.read(trafficHistoryAck{})
	if len(batch.Records) != 256 || batch.DroppedBytes != 3 {
		t.Fatal(batch)
	}
	if replay := collector.read(trafficHistoryAck{}); !reflect.DeepEqual(batch, replay) {
		t.Fatal("gap indication not replayable")
	}
}

func TestTrafficHistoryCapturesClosedShortConnections(t *testing.T) {
	collector := newTrafficHistoryCollector()
	manager := &statistic.Manager{}
	previousRequest := statistic.DefaultRequestNotify
	statistic.DefaultRequestNotify = nil
	defer func() { statistic.DefaultRequestNotify = previousRequest }()
	previous := statistic.DefaultTrafficNotify
	statistic.DefaultTrafficNotify = func(info *statistic.TrackerInfo, upload, download int64) {
		collector.record(info, upload, download, time.Unix(1800000000, 0))
	}
	defer func() { statistic.DefaultTrafficNotify = previous }()
	for _, tracked := range []bool{true, false} {
		local, peer := net.Pipe()
		conn := outbound.NewConn(local, outbound.NewDirectWithOption(outbound.DirectOption{Name: "node"}))
		tracker := statistic.NewTCPTracker(conn, manager,
			&C.Metadata{Process: "browser", ProcessPath: "/browser"}, nil, 5, 0, tracked)
		readDone := make(chan error, 1)
		go func() { buffer := make([]byte, 7); _, err := peer.Read(buffer); readDone <- err }()
		if _, err := tracker.Write([]byte("payload")); err != nil {
			t.Fatal(err)
		}
		if err := <-readDone; err != nil {
			t.Fatal(err)
		}
		_ = tracker.Close()
		_ = peer.Close()
	}
	batch := collector.read(trafficHistoryAck{})
	if len(batch.Records) != 1 || batch.Records[0].Upload != 12 {
		t.Fatalf("short connection lost or internal tracker counted: %+v", batch)
	}
}
