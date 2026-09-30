import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


LIMITS = {'GLIBC': (2, 31), 'GLIBCXX': (3, 4, 28)}
VERSION_PATTERN = re.compile(r'\b(GLIBCXX|GLIBC)_([0-9]+(?:\.[0-9]+)+)\b')
FORBIDDEN_GLIB = re.compile(r'\bg_once_init_(?:enter|leave)_pointer\b')


def version_requirements(symbols):
    requirements = {}
    for line in symbols.splitlines():
        if ' UND ' not in line:
            continue
        for family, version in VERSION_PATTERN.findall(line):
            number = tuple(int(part) for part in version.split('.'))
            requirements[family] = max(requirements.get(family, ()), number)
    return requirements


def inspect_bundle(bundle, check_load=False):
    errors = []
    count = 0
    environment = dict(os.environ)
    environment.pop('LD_PRELOAD', None)
    environment['LD_LIBRARY_PATH'] = str(bundle / 'lib')
    for binary in sorted(bundle.rglob('*')):
        if not binary.is_file():
            continue
        with binary.open('rb') as source:
            if source.read(4) != b'\x7fELF':
                continue
        count += 1
        symbols = subprocess.run(
            ['readelf', '--dyn-syms', '--wide', str(binary)],
            capture_output=True, text=True, check=True,
        ).stdout
        relative = binary.relative_to(bundle)
        requirements = version_requirements(symbols)
        for family, version in requirements.items():
            if version > LIMITS[family]:
                errors.append(f'{relative}: requires {family}_{".".join(map(str, version))}')
        if FORBIDDEN_GLIB.search(symbols):
            errors.append(f'{relative}: requires GLib 2.80 pointer initialization API')
        if check_load and ' UND ' in symbols:
            result = subprocess.run(
                ['ldd', '-r', str(binary)], capture_output=True, text=True,
                env=environment,
            )
            output = result.stdout + result.stderr
            if result.returncode or 'not found' in output or 'undefined symbol:' in output:
                errors.append(f'{relative}: loader check failed\n{output.strip()}')
    if not count:
        errors.append('No ELF binaries found in bundle')
    return count, errors


def main():
    parser = argparse.ArgumentParser(description='Check Ubuntu 20.04 Linux bundle ABI baseline')
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--check-load', action='store_true')
    arguments = parser.parse_args()
    count, errors = inspect_bundle(arguments.bundle.resolve(), arguments.check_load)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'Linux ABI check passed: {count} ELF files, GLIBC <= 2.31, GLIBCXX <= 3.4.28')
    return 0


if __name__ == '__main__':
    sys.exit(main())
