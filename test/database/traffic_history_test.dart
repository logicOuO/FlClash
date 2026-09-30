import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart' as fl;
import 'package:fl_clash/models/traffic_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

TrafficHistoryRecord record({
  int minute = 1800000000,
  String processPath = '/opt/browser',
  String process = 'browser',
  bool proxy = true,
  int upload = 10,
  int download = 20,
}) => TrafficHistoryRecord(
  minute: minute,
  process: process,
  processPath: processPath,
  proxy: proxy,
  upload: upload,
  download: download,
);

TrafficHistoryBatch batch(
  int sequence,
  List<TrafficHistoryRecord> records, {
  String session = 'session-1',
  int droppedBytes = 0,
}) => TrafficHistoryBatch(
  session: session,
  sequence: sequence,
  records: records,
  droppedBytes: droppedBytes,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late fl.Database database;

  setUp(() => database = fl.Database(NativeDatabase.memory()));
  tearDown(() => database.close());

  Future<List<ApplicationTraffic>> usage({
    bool proxy = true,
    int start = 1800000000,
    int end = 1800000060,
  }) {
    return database.trafficHistoryDao
        .watchUsage(
          start: DateTime.fromMillisecondsSinceEpoch(start * 1000),
          end: DateTime.fromMillisecondsSinceEpoch(end * 1000),
          proxy: proxy,
        )
        .first;
  }

  test('replayed and older batches are not counted twice', () async {
    final first = batch(1, [record()]);
    await database.trafficHistoryDao.saveBatch(first);
    await database.trafficHistoryDao.saveBatch(first);
    await database.trafficHistoryDao.saveBatch(
      batch(2, [record(upload: 3, download: 4)]),
    );
    await database.trafficHistoryDao.saveBatch(first);
    final rows = await usage();
    expect(rows.single.upload, 13);
    expect(rows.single.download, 24);
    await database.trafficHistoryDao.saveBatch(
      batch(1, [record()], session: 'restarted-core'),
    );
    expect((await usage()).single.total, 67);
  });

  test('time range is half-open and distinguishes paths and routes', () async {
    await database.trafficHistoryDao.saveBatch(
      batch(1, [
        record(),
        record(minute: 1800000060, upload: 100),
        record(proxy: false, upload: 500),
        record(processPath: '/other/browser', upload: 40),
        record(process: '', processPath: '', upload: 1, download: 2),
      ]),
    );
    final rows = await usage();
    expect(rows, hasLength(3));
    expect(rows.map((row) => row.total), [60, 30, 3]);
    expect(rows.first.processPath, '/other/browser');
    expect((await usage(proxy: false)).single.upload, 500);
    expect(
      (await usage(start: 1800000060, end: 1800000120)).single.upload,
      100,
    );
  });

  test(
    'failed transaction can retry without partially counting traffic',
    () async {
      await database.customStatement(
        'CREATE TRIGGER fail_history BEFORE INSERT ON traffic_history_sessions '
        "BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      );
      final first = batch(1, [record()]);
      await expectLater(
        database.trafficHistoryDao.saveBatch(first),
        throwsA(anything),
      );
      expect(await usage(), isEmpty);
      await database.customStatement('DROP TRIGGER fail_history');
      await database.trafficHistoryDao.saveBatch(first);
      expect((await usage()).single.total, 30);
    },
  );

  test('gap-only batches are persisted and replay safe', () async {
    final gap = batch(1, [], droppedBytes: 123);
    await database.trafficHistoryDao.saveBatch(gap);
    await database.trafficHistoryDao.saveBatch(gap);
    expect(await database.trafficHistoryDao.watchDroppedBytes().first, 123);
    await database.trafficHistoryDao.saveBatch(
      batch(2, [record()], droppedBytes: 7),
    );
    expect(await database.trafficHistoryDao.watchDroppedBytes().first, 130);
  });

  test('usage stream updates after a saved batch', () async {
    final stream = database.trafficHistoryDao.watchUsage(
      start: DateTime.fromMillisecondsSinceEpoch(1800000000000),
      end: DateTime.fromMillisecondsSinceEpoch(1800000060000),
    );
    final update = expectLater(
      stream,
      emitsInOrder([
        isEmpty,
        isA<List<ApplicationTraffic>>().having(
          (rows) => rows.single.total,
          'total',
          30,
        ),
      ]),
    );
    await Future<void>.delayed(Duration.zero);
    await database.trafficHistoryDao.saveBatch(batch(1, [record()]));
    await update;
  });

  test(
    'v3 migration preserves existing data and history survives reopen',
    () async {
      await database.close();
      final raw = sqlite3.openInMemory();
      addTearDown(raw.close);
      final seed = fl.Database(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await seed.customSelect('SELECT 1').get();
      await seed.customStatement(
        "INSERT INTO scripts (id, label, last_update_time) VALUES (42, 'preserved', 0)",
      );
      await seed.close();
      raw.execute('DROP TABLE traffic_history_buckets');
      raw.execute('DROP TABLE traffic_history_sessions');
      raw.execute('PRAGMA user_version = 3');
      final migrated = fl.Database(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await migrated.trafficHistoryDao.saveBatch(batch(1, [record()]));
      expect(
        (await migrated.customSelect('SELECT label FROM scripts').getSingle())
            .read<String>('label'),
        'preserved',
      );
      await migrated.close();
      final reopened = fl.Database(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(reopened.close);
      final rows = await reopened.trafficHistoryDao
          .watchUsage(
            start: DateTime.fromMillisecondsSinceEpoch(1800000000000),
            end: DateTime.fromMillisecondsSinceEpoch(1800000060000),
          )
          .first;
      expect(rows.single.total, 30);
      expect(raw.select('PRAGMA user_version').single['user_version'], 4);
    },
  );
}
