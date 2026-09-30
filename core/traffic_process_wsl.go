package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"net/netip"
	"path"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf16"
)

const trafficWSLScript = `tcp=$(ss -H -ntp 2>/dev/null)
udp=$(ss -H -anup 2>/dev/null)
printf 'TCP\n%s\nUDP\n%s\nPATHS\n' "$tcp" "$udp"
printf '%s\n%s\n' "$tcp" "$udp" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | while IFS= read -r process_id; do
  executable=$(readlink "/proc/$process_id/exe" 2>/dev/null)
  if [ -n "$executable" ]; then
    printf '%s\t%s\n' "$process_id" "$executable"
  fi
done`

var trafficWSLPID = regexp.MustCompile(`pid=([0-9]+)`)

type trafficWSLCommand func(context.Context, ...string) ([]byte, error)

func decodeWSLDistributionList(data []byte) []string {
	text := string(data)
	if len(data) >= 2 && (data[0] == 0xff && data[1] == 0xfe || data[1] == 0) {
		words := make([]uint16, 0, len(data)/2)
		for offset := 0; offset+1 < len(data); offset += 2 {
			words = append(words, binary.LittleEndian.Uint16(data[offset:]))
		}
		text = string(utf16.Decode(words))
	}
	var names []string
	for _, line := range strings.Split(strings.TrimPrefix(text, "\ufeff"), "\n") {
		name := strings.TrimSpace(line)
		if name != "" {
			names = append(names, name)
		}
	}
	return names
}

func scanWSLTrafficProcesses(ctx context.Context, command trafficWSLCommand) (map[trafficProcessSource]trafficProcessIdentity, error) {
	data, err := command(ctx, "--list", "--running", "--quiet")
	if err != nil {
		return nil, err
	}
	result := make(map[trafficProcessSource]trafficProcessIdentity)
	ambiguous := make(map[trafficProcessSource]bool)
	for index, distribution := range decodeWSLDistributionList(data) {
		if index >= 16 || ctx.Err() != nil {
			break
		}
		output, err := command(ctx, "--distribution", distribution, "--user", "root", "--exec", "sh", "-c", trafficWSLScript)
		if err != nil {
			continue
		}
		for source, identity := range parseWSLTrafficProcesses(distribution, string(output)) {
			if previous, exists := result[source]; exists && previous != identity {
				delete(result, source)
				ambiguous[source] = true
			}
			if !ambiguous[source] {
				result[source] = identity
			}
		}
	}
	return result, nil
}

func parseWSLTrafficProcesses(distribution, output string) map[trafficProcessSource]trafficProcessIdentity {
	paths := make(map[string]string)
	lines := strings.Split(output, "\n")
	pathSection := false
	for _, line := range lines {
		line = strings.TrimSuffix(line, "\r")
		if line == "PATHS" {
			pathSection = true
			continue
		}
		if pathSection {
			fields := strings.SplitN(line, "\t", 2)
			if len(fields) == 2 && strings.HasPrefix(fields[1], "/") && !strings.HasSuffix(fields[1], " (deleted)") {
				paths[fields[0]] = fields[1]
			}
		}
	}
	result := make(map[trafficProcessSource]trafficProcessIdentity)
	network := ""
	ambiguous := make(map[trafficProcessSource]bool)
	for _, line := range lines {
		switch strings.TrimSpace(line) {
		case "TCP":
			network = "tcp"
			continue
		case "UDP":
			network = "udp"
			continue
		case "PATHS":
			return result
		}
		fields := strings.Fields(line)
		if network == "" || len(fields) < 6 || network == "tcp" && fields[0] != "ESTAB" {
			continue
		}
		address, err := parseTrafficSocketAddress(fields[3])
		if err != nil || !address.IsValid() || address.Port() == 0 {
			continue
		}
		inbound, _ := parseTrafficSocketAddress(fields[4])
		var identity trafficProcessIdentity
		for _, match := range trafficWSLPID.FindAllStringSubmatch(line, -1) {
			if executable := paths[match[1]]; executable != "" {
				candidate := trafficProcessIdentity{path.Base(executable), "wsl://" + distribution + executable}
				if identity.Path != "" && identity != candidate {
					identity = trafficProcessIdentity{}
					break
				}
				identity = candidate
			}
		}
		if identity.Path != "" {
			source := trafficProcessSource{network, address, inbound}
			if previous, exists := result[source]; exists && previous != identity {
				delete(result, source)
				ambiguous[source] = true
			}
			if !ambiguous[source] {
				result[source] = identity
			}
		}
	}
	return result
}

func parseTrafficSocketAddress(value string) (netip.AddrPort, error) {
	separator := strings.LastIndexByte(value, ':')
	if separator < 0 {
		return netip.AddrPort{}, fmt.Errorf("invalid socket address")
	}
	portText := value[separator+1:]
	if portText == "*" {
		portText = "0"
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil {
		return netip.AddrPort{}, err
	}
	addressText := strings.Trim(value[:separator], "[]")
	if addressText == "*" {
		addressText = "0.0.0.0"
	}
	address, err := netip.ParseAddr(addressText)
	if err != nil {
		return netip.AddrPort{}, err
	}
	return netip.AddrPortFrom(address.Unmap(), uint16(port)), nil
}
