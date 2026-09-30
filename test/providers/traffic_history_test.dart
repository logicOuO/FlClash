import 'dart:async';

import 'package:drift/native.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/traffic_history.dart';
import 'package:fl_clash/providers/traffic_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  late _Core handler;
  late TrafficHistoryRecorder recorder;

  setUp(() {
    database = Database(NativeDatabase.memory());
    handler = _Core();
    recorder = TrafficHistoryRecorder(
      core: CoreController.scoped(handler),
      store: database.trafficHistoryDao,
      connected: () => true,
    );
  });
  tearDown(() async {
    recorder.dispose();
    await database.close();
  });

  test('acknowledges only successfully persisted batches', () async {
    const first = TrafficHistoryBatch(
      session: 'core',
      sequence: 1,
      records: [
        TrafficHistoryRecord(
          minute: 1800000000,
          process: 'app',
          processPath: '/app',
          proxy: true,
          upload: 10,
          download: 20,
        ),
      ],
    );
    final acknowledgments = <int>[];
    when(
      () => handler.getTrafficHistory(
        session: any(named: 'session'),
        sequence: any(named: 'sequence'),
        flush: any(named: 'flush'),
      ),
    ).thenAnswer((invocation) async {
      acknowledgments.add(invocation.namedArguments[#sequence] as int);
      return first;
    });
    await database.customStatement(
      'CREATE TRIGGER fail_history BEFORE INSERT ON traffic_history_sessions '
      "BEGIN SELECT RAISE(ABORT, 'failure'); END",
    );
    await expectLater(recorder.synchronize(), throwsA(anything));
    await database.customStatement('DROP TRIGGER fail_history');
    await recorder.synchronize();
    await recorder.synchronize();
    expect(acknowledgments, [0, 0, 1]);
  });

  test('overlapping synchronization shares one operation', () async {
    final gate = Completer<TrafficHistoryBatch>();
    when(
      () => handler.getTrafficHistory(session: '', sequence: 0),
    ).thenAnswer((_) => gate.future);
    final first = recorder.synchronize();
    final second = recorder.synchronize();
    expect(identical(first, second), isTrue);
    gate.complete(
      const TrafficHistoryBatch(session: 'core', sequence: 0, records: []),
    );
    await Future.wait([first, second]);
    verify(() => handler.getTrafficHistory(session: '', sequence: 0)).called(1);
  });

  test('final flush waits for old work then reads a fresh batch', () async {
    final gate = Completer<TrafficHistoryBatch>();
    var reads = 0;
    when(
      () => handler.getTrafficHistory(
        session: any(named: 'session'),
        sequence: any(named: 'sequence'),
        flush: any(named: 'flush'),
      ),
    ).thenAnswer((_) {
      reads++;
      if (reads == 1) return gate.future;
      if (reads > 2) {
        return Future.value(
          const TrafficHistoryBatch(session: 'core', sequence: 2, records: []),
        );
      }
      return Future.value(
        const TrafficHistoryBatch(
          session: 'core',
          sequence: 2,
          records: [
            TrafficHistoryRecord(
              minute: 1800000000,
              process: 'app',
              processPath: '/app',
              proxy: true,
              upload: 2,
              download: 0,
            ),
          ],
        ),
      );
    });
    final active = recorder.synchronize();
    final flush = recorder.flushSafely();
    gate.complete(
      const TrafficHistoryBatch(
        session: 'core',
        sequence: 1,
        records: [
          TrafficHistoryRecord(
            minute: 1800000000,
            process: 'app',
            processPath: '/app',
            proxy: true,
            upload: 1,
            download: 0,
          ),
        ],
      ),
    );
    await Future.wait([active, flush]);
    expect(reads, 3);
    verify(
      () =>
          handler.getTrafficHistory(session: 'core', sequence: 1, flush: true),
    ).called(1);
    final rows = await database.trafficHistoryDao
        .watchUsage(
          start: DateTime.fromMillisecondsSinceEpoch(1800000000000),
          end: DateTime.fromMillisecondsSinceEpoch(1800000060000),
        )
        .first;
    expect(rows.single.upload, 3);
  });

  test('final flush has a bounded wait when Core is unresponsive', () async {
    final gate = Completer<TrafficHistoryBatch>();
    when(
      () => handler.getTrafficHistory(session: '', sequence: 0, flush: true),
    ).thenAnswer((_) => gate.future);
    await recorder.flushSafely();
    recorder.dispose();
    gate.complete(
      const TrafficHistoryBatch(session: 'core', sequence: 0, records: []),
    );
    await Future<void>.delayed(Duration.zero);
  });

  test('disconnected or disposed recorder makes no Core calls', () async {
    final disconnected = TrafficHistoryRecorder(
      core: CoreController.scoped(handler),
      store: database.trafficHistoryDao,
      connected: () => false,
    );
    await disconnected.synchronize();
    disconnected.dispose();
    recorder.dispose();
    await recorder.synchronize();
    verifyNever(
      () => handler.getTrafficHistory(
        session: any(named: 'session'),
        sequence: any(named: 'sequence'),
        flush: any(named: 'flush'),
      ),
    );
  });
}
