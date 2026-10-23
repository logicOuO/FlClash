//go:build with_gvisor

package packetflow

import (
	"context"
	"errors"
	"io"
	"sync"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
)

type Device struct {
	endpoint *channel.Endpoint
	mtu      int
	cancel   context.CancelFunc
	done     chan struct{}
	output   func([]byte)
	once     sync.Once
}

func New(mtu int, output func([]byte)) *Device {
	ctx, cancel := context.WithCancel(context.Background())
	d := &Device{endpoint: channel.New(128, uint32(mtu), ""), mtu: mtu, cancel: cancel, done: make(chan struct{}), output: output}
	go func() {
		defer close(d.done)
		for {
			packet := d.endpoint.ReadContext(ctx)
			if packet == nil {
				return
			}
			d.WritePacket(packet)
			packet.DecRef()
		}
	}()
	return d
}

func (d *Device) Input(data []byte) error {
	if len(data) == 0 || len(data) > d.mtu {
		return errors.New("invalid packet size")
	}
	select {
	case <-d.done:
		return io.ErrClosedPipe
	default:
	}
	protocol := header.IPv4ProtocolNumber
	switch data[0] >> 4 {
	case 4:
		if len(data) < header.IPv4MinimumSize {
			return errors.New("short IPv4 packet")
		}
	case 6:
		if len(data) < header.IPv6MinimumSize {
			return errors.New("short IPv6 packet")
		}
		protocol = header.IPv6ProtocolNumber
	default:
		return errors.New("invalid IP version")
	}
	packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte(nil), data...))})
	defer packet.DecRef()
	d.endpoint.InjectInbound(protocol, packet)
	return nil
}

func (d *Device) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	return d.endpoint, stack.NICOptions{}, nil
}

func (d *Device) WritePacket(packet *stack.PacketBuffer) (int, error) {
	view := packet.ToView()
	defer view.Release()
	d.output(view.AsSlice())
	return view.Size(), nil
}

func (d *Device) Read([]byte) (int, error)  { return 0, errors.ErrUnsupported }
func (d *Device) Write([]byte) (int, error) { return 0, errors.ErrUnsupported }
func (d *Device) Close() error {
	d.once.Do(func() { d.cancel(); d.endpoint.Close(); <-d.done })
	return nil
}
