part of 'database.dart';

class TrafficHistoryBuckets extends Table {
  IntColumn get minute => integer()();
  TextColumn get process => text()();
  TextColumn get processPath => text()();
  BoolColumn get proxy => boolean()();
  IntColumn get upload => integer()();
  IntColumn get download => integer()();

  @override
  Set<Column> get primaryKey => {minute, process, processPath, proxy};
}

class TrafficHistorySessions extends Table {
  TextColumn get session => text()();
  IntColumn get sequence => integer()();
  IntColumn get droppedBytes => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {session};
}

@DriftAccessor(tables: [TrafficHistoryBuckets, TrafficHistorySessions])
class TrafficHistoryDao extends DatabaseAccessor<Database>
    with _$TrafficHistoryDaoMixin {
  TrafficHistoryDao(super.attachedDatabase);

  Future<void> saveBatch(TrafficHistoryBatch batch) async {
    if (batch.records.isEmpty && batch.droppedBytes == 0) return;
    await transaction(() async {
      final previous = await (select(
        trafficHistorySessions,
      )..where((row) => row.session.equals(batch.session))).getSingleOrNull();
      if (previous != null && previous.sequence >= batch.sequence) return;
      for (final record in batch.records) {
        await customStatement(
          'INSERT INTO traffic_history_buckets '
          '(minute, process, process_path, proxy, upload, download) VALUES (?, ?, ?, ?, ?, ?) '
          'ON CONFLICT (minute, process, process_path, proxy) DO UPDATE SET '
          'upload = upload + excluded.upload, download = download + excluded.download',
          [
            record.minute,
            record.process,
            record.processPath,
            record.proxy ? 1 : 0,
            record.upload,
            record.download,
          ],
        );
      }
      await into(trafficHistorySessions).insertOnConflictUpdate(
        TrafficHistorySessionsCompanion.insert(
          session: batch.session,
          sequence: batch.sequence,
          droppedBytes: Value(
            (previous?.droppedBytes ?? 0) + batch.droppedBytes,
          ),
        ),
      );
      notifyUpdates({TableUpdate.onTable(trafficHistoryBuckets)});
    });
  }

  Stream<int> watchDroppedBytes() {
    return customSelect(
      'SELECT COALESCE(SUM(dropped_bytes), 0) AS lost FROM traffic_history_sessions',
      readsFrom: {trafficHistorySessions},
    ).watchSingle().map((row) => row.read<int>('lost'));
  }

  Stream<List<ApplicationTraffic>> watchUsage({
    required DateTime start,
    required DateTime end,
    bool proxy = true,
  }) {
    return customSelect(
      'SELECT process, process_path, SUM(upload) AS upload, SUM(download) AS download '
      'FROM traffic_history_buckets WHERE minute >= ? AND minute < ? AND proxy = ? '
      'GROUP BY process, process_path ORDER BY SUM(upload) + SUM(download) DESC',
      variables: [
        Variable(start.millisecondsSinceEpoch ~/ 1000),
        Variable(end.millisecondsSinceEpoch ~/ 1000),
        Variable(proxy ? 1 : 0),
      ],
      readsFrom: {trafficHistoryBuckets},
    ).watch().map(
      (rows) => rows
          .map(
            (row) => ApplicationTraffic(
              process: row.read<String>('process'),
              processPath: row.read<String>('process_path'),
              upload: row.read<int>('upload'),
              download: row.read<int>('download'),
            ),
          )
          .toList(),
    );
  }
}
