"""Supply iOS-only fallbacks without modifying the mihomo submodule."""
import json
import sys
from pathlib import Path

root, output = (Path(arg).resolve() for arg in sys.argv[1:])
patches = {
    'component/memory/memory_darwin.go': '''package memory
func GetMemoryInfo(pid int32) (*MemoryInfoStat, error) {
    return nil, ErrNotImplementedError
}
''',
    'component/memory/memory_darwin_arm64.s': '\n',
    'component/process/process_darwin.go': '''package process
import "net/netip"
func findProcessName(network string, ip netip.Addr, port int) (uint32, string, error) {
    return 0, "", ErrPlatformNotSupport
}
''',
}
replacements = {}
output.mkdir(parents=True, exist_ok=True)
for name, content in patches.items():
    source = root / 'core' / 'Clash.Meta' / name
    if not source.is_file():
        raise SystemExit(f'Mihomo overlay source has moved: {source}')
    target = output / source.name
    target.write_text(content, encoding='utf-8')
    replacements[str(source)] = str(target)
(output / 'overlay.json').write_text(json.dumps({'Replace': replacements}), encoding='utf-8')
