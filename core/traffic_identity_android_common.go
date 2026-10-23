package main

import (
	"fmt"
	"net/url"
	"sync/atomic"

	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var trafficPackageNames atomic.Pointer[func(uint32) string]

func prepareAndroidTrafficIdentity(info *statistic.TrackerInfo) {
	if info == nil || info.Metadata == nil {
		return
	}
	metadata := *info.Metadata
	if metadata.Process == "" && tunnel.FindProcessMode() != process.FindProcessOff {
		if name, err := process.FindPackageName(&metadata); err == nil {
			metadata.Process = name
		}
	}
	if lookup := trafficPackageNames.Load(); lookup != nil && (metadata.Process != "" || metadata.Uid > 0) {
		metadata.Process = (*lookup)(metadata.Uid)
	}
	if metadata.Process != "" {
		metadata.ProcessPath = fmt.Sprintf("android://%d/%s", metadata.Uid, url.PathEscape(metadata.Process))
	} else if metadata.Uid > 0 {
		metadata.Process = fmt.Sprintf("UID %d", metadata.Uid)
		metadata.ProcessPath = fmt.Sprintf("android-uid://%d", metadata.Uid)
	}
	info.Metadata = &metadata
}
