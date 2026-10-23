//go:build with_gvisor

package packetflow

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"
	"time"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
)

type receiver struct{ packets chan []byte }

func (r *receiver) DeliverNetworkPacket(_ tcpip.NetworkProtocolNumber, p *stack.PacketBuffer) {
	v := p.ToView()
	defer v.Release()
	r.packets <- append([]byte(nil), v.AsSlice()...)
}
func (*receiver) DeliverLinkPacket(tcpip.NetworkProtocolNumber, *stack.PacketBuffer) {}

func TestPacketInputCopiesAndValidates(t *testing.T) {
	d := New(1500, func([]byte) {})
	defer d.Close()
	r := &receiver{packets: make(chan []byte, 1)}
	d.endpoint.Attach(r)
	for _, data := range [][]byte{nil, {0x40}, make([]byte, 1501), {0x70}} {
		if err := d.Input(data); err == nil {
			t.Fatal("accepted invalid packet")
		}
	}
	for _, size := range []int{20, 40} {
		data := make([]byte, size)
		data[0] = 0x45
		if size == 40 {
			data[0] = 0x60
		}
		want := append([]byte(nil), data...)
		if err := d.Input(data); err != nil {
			t.Fatal(err)
		}
		data[0] = 0
		select {
		case got := <-r.packets:
			if !bytes.Equal(want, got) {
				t.Fatal("packet changed across ownership boundary")
			}
		case <-time.After(time.Second):
			t.Fatal("packet not delivered")
		}
	}
	d.Close()
	if err := d.Input(make([]byte, 20)); !errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("closed device: %v", err)
	}
}

func TestStackOutputPreservesPacketAndReleasesPump(t *testing.T) {
	output := make(chan []byte, 2)
	d := New(1500, func(b []byte) { output <- append([]byte(nil), b...) })
	want := []byte{0x45, 0, 0, 20}
	p := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(want)})
	p.NetworkProtocolNumber = header.IPv4ProtocolNumber
	var packets stack.PacketBufferList
	packets.PushBack(p)
	if _, err := d.endpoint.WritePackets(packets); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-output:
		if !bytes.Equal(got, want) {
			t.Fatal("output changed")
		}
	case <-time.After(time.Second):
		t.Fatal("output stalled")
	}
	if _, err := d.WritePacket(p); err != nil {
		t.Fatal(err)
	}
	p.DecRef()
	d.Close()
	d.Close()
	select {
	case <-d.done:
	default:
		t.Fatal("pump leaked")
	}
}

func TestMihomoStackStartsWithoutSystemTun(t *testing.T) {
	device := New(1500, func([]byte) {})
	defer device.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stack, err := NewStack(ctx, device)
	if err != nil {
		t.Fatal(err)
	}
	if err := stack.Start(); err != nil {
		t.Fatal(err)
	}
	if err := stack.Close(); err != nil {
		t.Fatal(err)
	}
}
