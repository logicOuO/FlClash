package main

import (
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	P "github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type trafficHistoryKey struct {
	Minute      int64  `json:"minute"`
	Process     string `json:"process"`
	ProcessPath string `json:"processPath"`
	Proxy       bool   `json:"proxy"`
}

type trafficHistoryRecord struct {
	trafficHistoryKey
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
}

type trafficHistoryBatch struct {
	Session      string                 `json:"session"`
	Sequence     int64                  `json:"sequence"`
	Records      []trafficHistoryRecord `json:"records"`
	DroppedBytes int64                  `json:"droppedBytes"`
}

type trafficHistoryAck struct {
	Session  string `json:"session"`
	Sequence int64  `json:"sequence"`
	Flush    bool   `json:"flush,omitempty"`
}

type trafficAttributionKey struct {
	History trafficHistoryKey
	Process trafficProcessKey
}

type trafficHistoryCollector struct {
	mu           sync.Mutex
	session      string
	sequence     int64
	records      map[trafficHistoryKey]Traffic
	pending      *trafficHistoryBatch
	droppedBytes int64
	resolver     *trafficProcessResolver
	unattributed map[trafficAttributionKey]Traffic
}

func newTrafficHistoryCollector() *trafficHistoryCollector {
	return &trafficHistoryCollector{
		session:      utils.NewUUIDV4().String(),
		records:      make(map[trafficHistoryKey]Traffic),
		unattributed: make(map[trafficAttributionKey]Traffic),
	}
}

var trafficHistory = func() *trafficHistoryCollector {
	collector := newTrafficHistoryCollector()
	collector.resolver = platformTrafficProcessResolver()
	return collector
}()

func init() {
	statistic.DefaultTrafficNotify = func(info *statistic.TrackerInfo, upload, download int64) {
		trafficHistory.record(info, upload, download, time.Now())
	}
}

func (collector *trafficHistoryCollector) record(info *statistic.TrackerInfo, upload, download int64, now time.Time) {
	if info == nil || info.Metadata == nil || (upload <= 0 && download <= 0) {
		return
	}
	processPath := info.Metadata.ProcessPath
	process := info.Metadata.Process
	if runtime.GOOS == "windows" && !strings.HasPrefix(processPath, "wsl://") {
		processPath = strings.ToLower(processPath)
		process = strings.ToLower(process)
	}
	key := trafficHistoryKey{
		Minute:      now.Unix() / 60 * 60,
		Process:     process,
		ProcessPath: processPath,
		Proxy:       len(info.Chain) > 0 && info.Chain.Last() != "DIRECT",
	}
	collector.mu.Lock()
	defer collector.mu.Unlock()
	if processPath == "" && process == "" {
		source := trafficSourceFor(info)
		key.ProcessPath = source.description()
		if collector.resolver != nil && tunnel.FindProcessMode() != P.FindProcessOff {
			processKey := trafficProcessKey{info.UUID.String(), source}
			identity, pending := collector.resolver.lookup(processKey, now, true)
			if identity.Path != "" {
				key.Process, key.ProcessPath = identity.Name, identity.Path
			} else if pending {
				attribution := trafficAttributionKey{key, processKey}
				if _, exists := collector.unattributed[attribution]; exists || len(collector.unattributed) < 8192 {
					traffic := collector.unattributed[attribution]
					traffic.Up += max(upload, 0)
					traffic.Down += max(download, 0)
					collector.unattributed[attribution] = traffic
					return
				}
			}
		}
	}
	collector.add(key, Traffic{Up: max(upload, 0), Down: max(download, 0)})
}

func (collector *trafficHistoryCollector) add(key trafficHistoryKey, amount Traffic) {
	if runtime.GOOS == "windows" && !strings.HasPrefix(key.ProcessPath, "wsl://") {
		key.Process = strings.ToLower(key.Process)
		key.ProcessPath = strings.ToLower(key.ProcessPath)
	}
	if _, exists := collector.records[key]; !exists && len(collector.records) >= 65536 {
		collector.droppedBytes += amount.Up + amount.Down
		return
	}
	traffic := collector.records[key]
	traffic.Up += amount.Up
	traffic.Down += amount.Down
	collector.records[key] = traffic
}

func (collector *trafficHistoryCollector) read(ack trafficHistoryAck) trafficHistoryBatch {
	collector.mu.Lock()
	defer collector.mu.Unlock()
	for attribution, traffic := range collector.unattributed {
		identity, pending := collector.resolver.lookup(attribution.Process, time.Now(), false)
		if pending && !ack.Flush {
			continue
		}
		key := attribution.History
		if identity.Path != "" {
			key.Process, key.ProcessPath = identity.Name, identity.Path
		}
		collector.add(key, traffic)
		delete(collector.unattributed, attribution)
	}
	if collector.pending != nil && ack.Session == collector.session && ack.Sequence == collector.pending.Sequence {
		collector.pending = nil
	}
	if collector.pending != nil {
		return *collector.pending
	}
	records := make([]trafficHistoryRecord, 0, min(len(collector.records), 256))
	for key, traffic := range collector.records {
		records = append(records, trafficHistoryRecord{key, traffic.Up, traffic.Down})
		delete(collector.records, key)
		if len(records) == 256 {
			break
		}
	}
	if len(records) > 0 || collector.droppedBytes > 0 {
		collector.sequence++
		collector.pending = &trafficHistoryBatch{collector.session, collector.sequence, records, collector.droppedBytes}
		collector.droppedBytes = 0
		return *collector.pending
	}
	return trafficHistoryBatch{collector.session, collector.sequence, records, 0}
}
