package main

import (
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestTrafficJournalSurvivesCoreRestartAndReplaysUntilAcknowledged(t *testing.T) {
	path := filepath.Join(t.TempDir(), "history.db")
	collector := newTrafficHistoryCollector()
	journal, err := openTrafficJournal(path, collector)
	if err != nil {
		t.Fatal(err)
	}
	collector.record(historyInfo("android://10001/com.example.app", true), 11, 29, time.Now())
	if err := journal.capture(false); err != nil {
		t.Fatal(err)
	}
	first, err := journal.read(trafficHistoryAck{})
	if err != nil || len(first.Records) != 1 || first.Records[0].Upload != 11 {
		t.Fatalf("missing background traffic: %+v %v", first, err)
	}
	if err := journal.database.Close(); err != nil {
		t.Fatal(err)
	}
	restarted := newTrafficHistoryCollector()
	journal, err = openTrafficJournal(path, restarted)
	if err != nil {
		t.Fatal(err)
	}
	defer journal.database.Close()
	restarted.record(historyInfo("android://10001/com.example.app", true), 3, 7, time.Now())
	if err := journal.capture(false); err != nil {
		t.Fatal(err)
	}
	for _, ack := range []trafficHistoryAck{{}, {Session: "wrong", Sequence: first.Sequence}, {Session: first.Session, Sequence: first.Sequence + 1}} {
		replay, err := journal.read(ack)
		if err != nil || !reflect.DeepEqual(replay, first) {
			t.Fatalf("persisted batch changed: %+v %v", replay, err)
		}
	}
	second, err := journal.read(trafficHistoryAck{Session: first.Session, Sequence: first.Sequence})
	if err != nil || second.Session == first.Session || len(second.Records) != 1 || second.Records[0].Upload != 3 {
		t.Fatalf("restart lost or duplicated traffic: %+v %v", second, err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		empty, err := journal.read(trafficHistoryAck{Session: second.Session, Sequence: second.Sequence})
		if err != nil || len(empty.Records) != 0 {
			t.Fatalf("acknowledged traffic replayed: %+v %v", empty, err)
		}
	}
}

func TestTrafficJournalFailedWriteRetainsCollectorBatch(t *testing.T) {
	collector := newTrafficHistoryCollector()
	journal, err := openTrafficJournal(filepath.Join(t.TempDir(), "history.db"), collector)
	if err != nil {
		t.Fatal(err)
	}
	collector.record(historyInfo("android://10001/com.example.app", true), 8, 9, time.Now())
	if err := journal.database.Close(); err != nil {
		t.Fatal(err)
	}
	if err := journal.capture(false); err == nil {
		t.Fatal("closed database accepted a write")
	}
	batch := collector.read(trafficHistoryAck{})
	if len(batch.Records) != 1 || batch.Records[0].Upload != 8 || journal.ack.Session != "" {
		t.Fatalf("failed write acknowledged or discarded traffic: %+v", batch)
	}
}

func TestTrafficJournalMultiplePagesDoNotRepeatCapture(t *testing.T) {
	collector := newTrafficHistoryCollector()
	journal, err := openTrafficJournal(filepath.Join(t.TempDir(), "history.db"), collector)
	if err != nil {
		t.Fatal(err)
	}
	defer journal.database.Close()
	for minute := 0; minute < 600; minute++ {
		collector.record(historyInfo("app", true), 1, 2, time.Unix(int64(minute)*60, 0))
	}
	for attempt := 0; attempt < 2; attempt++ {
		if err := journal.capture(true); err != nil {
			t.Fatal(err)
		}
	}
	var ack trafficHistoryAck
	var upload int64
	for page := 0; page < 4; page++ {
		batch, err := journal.read(ack)
		if err != nil {
			t.Fatal(err)
		}
		for _, record := range batch.Records {
			upload += record.Upload
		}
		ack = trafficHistoryAck{Session: batch.Session, Sequence: batch.Sequence}
	}
	if upload != 600 {
		t.Fatalf("unexpected persisted total: %d", upload)
	}
}
