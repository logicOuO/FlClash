//go:build ios && cgo && with_gvisor

package main

/*
#include "bridge_ios.h"
*/
import "C"

import (
	"context"
	"core/packetflow"
	"encoding/json"
	"runtime/debug"
	"sync"
	"unsafe"

	"github.com/metacubex/mihomo/log"
	tun "github.com/metacubex/sing-tun"
)

var iosTun struct {
	sync.RWMutex
	device *packetflow.Device
	stack  tun.Stack
	cancel context.CancelFunc
}

func init() { debug.SetMemoryLimit(32 << 20) }

func (response MethodResponse) send() {
	data, err := response.JSON()
	if err != nil {
		data = []byte(`{"error":{"code":"encode_error","message":"Core response could not be encoded"}}`)
	}
	C.flclash_result(response.callback, (*C.uchar)(unsafe.Pointer(&data[0])), C.int(len(data)))
}

func deliverEvent(data []byte) {
	if len(data) > 0 {
		C.flclash_event((*C.uchar)(unsafe.Pointer(&data[0])), C.int(len(data)))
	}
}

//export flclash_invoke
func flclash_invoke(context unsafe.Pointer, data *C.char, length C.int) {
	call := &MethodCall{}
	if err := json.Unmarshal(C.GoBytes(unsafe.Pointer(data), length), call); err != nil {
		newMethodResponse("", context).failure("invalid_method_call", err.Error(), nil)
		return
	}
	go handleMethodCall(call, newMethodResponse(call.ID, context))
}

//export flclash_start_tun
func flclash_start_tun() C.int {
	iosTun.Lock()
	defer iosTun.Unlock()
	if iosTun.device != nil {
		return 0
	}
	device := packetflow.New(1500, func(data []byte) {
		if len(data) > 0 {
			C.flclash_packet((*C.uchar)(unsafe.Pointer(&data[0])), C.int(len(data)))
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	stack, err := packetflow.NewStack(ctx, device)
	if err == nil {
		err = stack.Start()
	}
	if err != nil {
		cancel()
		if stack != nil {
			stack.Close()
		}
		device.Close()
		log.Errorln("iOS packet stack: %v", err)
		return -1
	}
	iosTun.device, iosTun.stack, iosTun.cancel = device, stack, cancel
	return 0
}

//export flclash_input_packet
func flclash_input_packet(data *C.uchar, length C.int) C.int {
	if length <= 0 || length > 1500 {
		return -1
	}
	iosTun.RLock()
	defer iosTun.RUnlock()
	if iosTun.device == nil {
		return -1
	}
	if err := iosTun.device.Input(C.GoBytes(unsafe.Pointer(data), length)); err != nil {
		return -1
	}
	return 0
}

//export flclash_stop_tun
func flclash_stop_tun() {
	iosTun.Lock()
	defer iosTun.Unlock()
	if iosTun.device == nil {
		return
	}
	iosTun.cancel()
	iosTun.stack.Close()
	iosTun.device.Close()
	iosTun.device, iosTun.stack, iosTun.cancel = nil, nil, nil
	handleCloseConnections()
}
