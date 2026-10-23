package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	bolt "github.com/metacubex/bbolt"
)

var trafficJournalBucket = []byte("batches")
var activeTrafficJournal atomic.Pointer[trafficHistoryJournal]
var trafficJournalInitMu sync.Mutex

type trafficHistoryJournal struct {
	mu        sync.Mutex
	database  *bolt.DB
	collector *trafficHistoryCollector
	ack       trafficHistoryAck
}

func openTrafficJournal(path string, collector *trafficHistoryCollector) (*trafficHistoryJournal, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	database, err := bolt.Open(path, 0600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		return nil, err
	}
	err = database.Update(func(transaction *bolt.Tx) error {
		_, err := transaction.CreateBucketIfNotExists(trafficJournalBucket)
		return err
	})
	if err != nil {
		_ = database.Close()
		return nil, err
	}
	return &trafficHistoryJournal{database: database, collector: collector}, nil
}

func initTrafficJournal(home string) error {
	trafficJournalInitMu.Lock()
	defer trafficJournalInitMu.Unlock()
	path := filepath.Join(home, "traffic-history.db")
	if journal := activeTrafficJournal.Load(); journal != nil {
		if journal.database.Path() != path {
			return fmt.Errorf("traffic history is already open in another directory")
		}
		return nil
	}
	journal, err := openTrafficJournal(path, trafficHistory)
	if err != nil {
		return err
	}
	activeTrafficJournal.Store(journal)
	go func() {
		timer := time.NewTicker(2 * time.Second)
		defer timer.Stop()
		for range timer.C {
			if err := journal.capture(false); err != nil {
				logError("Traffic history persistence failed: %v", err)
			}
		}
	}()
	return nil
}

func (journal *trafficHistoryJournal) capture(flush bool) error {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	for page := 0; page < 256; page++ {
		ack := journal.ack
		ack.Flush = flush
		batch := journal.collector.read(ack)
		if len(batch.Records) == 0 && batch.DroppedBytes == 0 {
			return nil
		}
		data, err := json.Marshal(batch)
		if err != nil {
			return err
		}
		err = journal.database.Update(func(transaction *bolt.Tx) error {
			bucket := transaction.Bucket(trafficJournalBucket)
			sequence, err := bucket.NextSequence()
			if err != nil {
				return err
			}
			var key [8]byte
			binary.BigEndian.PutUint64(key[:], sequence)
			return bucket.Put(key[:], data)
		})
		if err != nil {
			return err
		}
		journal.ack = trafficHistoryAck{Session: batch.Session, Sequence: batch.Sequence}
	}
	return nil
}

func (journal *trafficHistoryJournal) read(ack trafficHistoryAck) (trafficHistoryBatch, error) {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	batch := trafficHistoryBatch{Records: []trafficHistoryRecord{}}
	err := journal.database.Update(func(transaction *bolt.Tx) error {
		bucket := transaction.Bucket(trafficJournalBucket)
		cursor := bucket.Cursor()
		key, data := cursor.First()
		if key == nil {
			return nil
		}
		if err := json.Unmarshal(data, &batch); err != nil {
			return err
		}
		if ack.Session != batch.Session || ack.Sequence != batch.Sequence {
			return nil
		}
		if err := cursor.Delete(); err != nil {
			return err
		}
		batch = trafficHistoryBatch{Records: []trafficHistoryRecord{}}
		if _, data = bucket.Cursor().First(); data != nil {
			return json.Unmarshal(data, &batch)
		}
		return nil
	})
	return batch, err
}

func readTrafficHistory(ack trafficHistoryAck) (trafficHistoryBatch, error) {
	journal := activeTrafficJournal.Load()
	if journal == nil {
		return trafficHistory.read(ack), nil
	}
	if err := journal.capture(ack.Flush); err != nil {
		return trafficHistoryBatch{}, err
	}
	return journal.read(ack)
}

func flushTrafficJournal() {
	if journal := activeTrafficJournal.Load(); journal != nil {
		if err := journal.capture(true); err != nil {
			logError("Traffic history flush failed: %v", err)
		}
	}
}
