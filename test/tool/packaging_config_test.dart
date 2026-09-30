import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('Linux release preserves the Ubuntu 20.04 ABI baseline', () {
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('GLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_64'));
    expect(cmake, contains('GLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_64'));
    final config =
        loadYaml(
              File('linux/packaging/deb/make_config.yaml').readAsStringSync(),
            )
            as YamlMap;
    expect(config['dependencies'], contains('libc6 (>= 2.31)'));
    expect(config['dependencies'], contains('libglib2.0-0 (>= 2.64)'));
    expect(config['dependencies'], contains('libgtk-3-0 (>= 3.24)'));
    final sqlite = File('linux/sqlite_compat.cmake').readAsStringSync();
    expect(sqlite, contains('URL_HASH SHA256='));
    expect(sqlite, contains('-Wl,-Bsymbolic'));
    final workflow =
        loadYaml(File('.github/workflows/build.yaml').readAsStringSync())
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final build = jobs['build'] as YamlMap;
    final strategy = build['strategy'] as YamlMap;
    final matrix = strategy['matrix'] as YamlMap;
    final entries = (matrix['include'] as YamlList).cast<YamlMap>();
    for (final entry in entries.where(
      (entry) => entry['platform'] == 'linux',
    )) {
      expect(entry['container'], 'ubuntu:20.04');
    }
  });

  group('Linux packaging teardown', () {
    for (final format in ['deb', 'rpm']) {
      test('$format removes the Helper unit only on a real uninstall', () {
        final config =
            loadYaml(
                  File(
                    'linux/packaging/$format/make_config.yaml',
                  ).readAsStringSync(),
                )
                as YamlMap;
        final scripts = (config['postuninstall_scripts'] as YamlList)
            .cast<String>();

        expect(scripts.first, contains('exit 0'));
        expect(
          scripts,
          contains('rm -f /etc/systemd/system/flclash-helper.service'),
        );
        expect(
          scripts.any((script) => script.contains('systemctl daemon-reload')),
          isTrue,
        );
      });
    }
  });

  test('rpm keeps the Core bytes the Helper was built against', () {
    final config =
        loadYaml(
              File('linux/packaging/rpm/make_config.yaml').readAsStringSync(),
            )
            as YamlMap;
    final macros = (config['spec_macros'] as YamlList).cast<String>();

    expect(macros, contains('%global debug_package %{nil}'));
    expect(macros, contains('%global __os_install_post %{nil}'));
  });
}
