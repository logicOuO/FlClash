//go:build with_gvisor

package packetflow

import (
	"context"
	"net/netip"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing"
	st "github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	tun "github.com/metacubex/sing-tun"
)

func NewStack(ctx context.Context, device *Device) (tun.Stack, error) {
	base, err := sing.NewListenerHandler(sing.ListenerConfig{Tunnel: tunnel.Tunnel, Type: constant.TUN})
	if err != nil {
		return nil, err
	}
	ipv4 := []netip.Prefix{netip.MustParsePrefix("198.18.0.1/30")}
	ipv6 := []netip.Prefix{netip.MustParsePrefix("fdfe:dcba:9876::1/126")}
	handler := &st.ListenerHandler{
		ListenerHandler: base,
		Inet4Address:    ipv4, Inet6Address: ipv6,
		DnsAddrPorts:          []netip.AddrPort{netip.MustParseAddrPort("0.0.0.0:53"), netip.MustParseAddrPort("[::]:53")},
		DisableICMPForwarding: true,
	}
	return tun.NewStack("gvisor", tun.StackOptions{
		Context: ctx, Tun: device,
		TunOptions: tun.Options{MTU: uint32(device.mtu), Inet4Address: ipv4, Inet6Address: ipv6},
		UDPTimeout: sing.UDPTimeout, ICMPTimeout: sing.ICMPTimeout,
		Handler: handler, Logger: log.SingLogger,
	})
}
