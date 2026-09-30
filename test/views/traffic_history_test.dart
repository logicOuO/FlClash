import 'dart:async';

import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/traffic_history.dart';
import 'package:fl_clash/providers/traffic_history.dart';
import 'package:fl_clash/views/traffic_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';

class _Store extends Mock implements TrafficHistoryDao {}

class _Recorder extends Mock implements TrafficHistoryRecorder {}

void main() {
  late _Store store;
  late _Recorder recorder;

  setUpAll(() => registerFallbackValue(DateTime(2026)));
  setUp(() {
    store = _Store();
    recorder = _Recorder();
    when(() => store.watchDroppedBytes()).thenAnswer((_) => Stream.value(0));
    when(() => recorder.synchronize()).thenAnswer((_) async {});
  });

  Future<void> mount(
    WidgetTester tester, {
    DateTime Function()? now,
    Size size = const Size(1100, 850),
    Locale locale = const Locale('en'),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TestApp(
        locale: locale,
        overrides: [
          trafficHistoryStoreProvider.overrideWithValue(store),
          trafficHistoryProvider.overrideWithValue(recorder),
        ],
        child: TrafficHistoryView(now: now),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  testWidgets('shows application totals, searches paths and switches routing', (
    tester,
  ) async {
    when(
      () => store.watchUsage(
        start: any(named: 'start'),
        end: any(named: 'end'),
        proxy: any(named: 'proxy'),
      ),
    ).thenAnswer(
      (invocation) => Stream.value(
        invocation.namedArguments[#proxy] == true
            ? const [
                ApplicationTraffic(
                  process: 'browser',
                  processPath: '/opt/browser',
                  upload: 100,
                  download: 200,
                ),
                ApplicationTraffic(
                  process: 'editor',
                  processPath: '/opt/editor',
                  upload: 20,
                  download: 30,
                ),
              ]
            : const [
                ApplicationTraffic(
                  process: 'updater',
                  processPath: '/usr/updater',
                  upload: 1,
                  download: 2,
                ),
              ],
      ),
    );
    await mount(tester);
    expect(find.text('browser'), findsOneWidget);
    expect(find.text('editor'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '/opt/editor');
    await tester.pumpAndSettle();
    expect(find.text('browser'), findsNothing);
    expect(find.text('editor'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.widgetWithText(FilterChip, 'Direct'));
    await tester.pumpAndSettle();
    expect(find.text('updater'), findsOneWidget);
    expect(find.text('editor'), findsNothing);
    await tester.tap(find.byTooltip('Refresh traffic history'));
    await tester.pumpAndSettle();
    verify(() => recorder.synchronize()).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows empty and query error states', (tester) async {
    when(
      () => store.watchUsage(
        start: any(named: 'start'),
        end: any(named: 'end'),
        proxy: any(named: 'proxy'),
      ),
    ).thenAnswer((_) => Stream.value([]));
    await mount(tester);
    expect(find.text('No data'), findsOneWidget);
    when(
      () => store.watchUsage(
        start: any(named: 'start'),
        end: any(named: 'end'),
        proxy: any(named: 'proxy'),
      ),
    ).thenAnswer((_) => Stream.error(StateError('database unavailable')));
    await tester.tap(find.byTooltip('Refresh traffic history'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not read traffic history. Please refresh.'),
      findsOneWidget,
    );
  });

  testWidgets('small desktop window scrolls controls without overflow', (
    tester,
  ) async {
    when(
      () => store.watchUsage(
        start: any(named: 'start'),
        end: any(named: 'end'),
        proxy: any(named: 'proxy'),
      ),
    ).thenAnswer(
      (_) => Stream.value(const [
        ApplicationTraffic(
          process: 'browser',
          processPath: '/opt/browser',
          upload: 10,
          download: 20,
        ),
      ]),
    );
    await mount(
      tester,
      size: const Size(380, 400),
      locale: const Locale('zh', 'CN'),
    );
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('browser'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh advances a preset across midnight', (tester) async {
    var now = DateTime(2026, 9, 30, 12);
    final starts = <DateTime>[];
    when(
      () => store.watchUsage(
        start: any(named: 'start'),
        end: any(named: 'end'),
        proxy: any(named: 'proxy'),
      ),
    ).thenAnswer((invocation) {
      starts.add(invocation.namedArguments[#start] as DateTime);
      return Stream.value([]);
    });
    await mount(tester, now: () => now);
    now = DateTime(2026, 10, 1, 12);
    await tester.tap(find.byTooltip('Refresh traffic history'));
    await tester.pumpAndSettle();
    expect(starts.last, DateTime(2026, 10, 1));
  });

  testWidgets('WSL identity and unresolved source remain visible', (
    tester,
  ) async {
    when(
      () => store.watchUsage(
        start: any(named: 'start'),
        end: any(named: 'end'),
        proxy: any(named: 'proxy'),
      ),
    ).thenAnswer(
      (_) => Stream.value(const [
        ApplicationTraffic(
          process: 'codex',
          processPath: 'wsl://Ubuntu-20.04/home/keye/Case/codex',
          upload: 100,
          download: 200,
        ),
        ApplicationTraffic(
          process: '',
          processPath: 'source://tcp/127.0.0.1:43933?inbound=7897',
          upload: 1,
          download: 2,
        ),
      ]),
    );
    await mount(tester, locale: const Locale('zh', 'CN'));
    expect(find.text('codex'), findsOneWidget);
    expect(find.text('未知'), findsOneWidget);
    expect(
      find.textContaining('wsl://Ubuntu-20.04/home/keye/Case/codex'),
      findsOneWidget,
    );
    expect(find.textContaining('source://tcp/127.0.0.1:43933'), findsOneWidget);
  });

  testWidgets('unknown processes and history gaps remain visible', (
    tester,
  ) async {
    when(
      () => store.watchUsage(
        start: any(named: 'start'),
        end: any(named: 'end'),
        proxy: any(named: 'proxy'),
      ),
    ).thenAnswer(
      (_) => Stream.value(const [
        ApplicationTraffic(
          process: '',
          processPath: '',
          upload: 1,
          download: 2,
        ),
      ]),
    );
    when(() => store.watchDroppedBytes()).thenAnswer((_) => Stream.value(123));
    await mount(tester);
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.textContaining('Missing traffic:'), findsOneWidget);
  });
}
