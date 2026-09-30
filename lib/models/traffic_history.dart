class TrafficHistoryRecord {
  final int minute;
  final String process;
  final String processPath;
  final bool proxy;
  final int upload;
  final int download;

  const TrafficHistoryRecord({
    required this.minute,
    required this.process,
    required this.processPath,
    required this.proxy,
    required this.upload,
    required this.download,
  });

  factory TrafficHistoryRecord.fromJson(Map<String, dynamic> json) {
    return TrafficHistoryRecord(
      minute: json['minute'] as int,
      process: json['process'] as String,
      processPath: json['processPath'] as String,
      proxy: json['proxy'] as bool,
      upload: json['upload'] as int,
      download: json['download'] as int,
    );
  }
}

class TrafficHistoryBatch {
  final String session;
  final int sequence;
  final List<TrafficHistoryRecord> records;
  final int droppedBytes;

  const TrafficHistoryBatch({
    required this.session,
    required this.sequence,
    required this.records,
    this.droppedBytes = 0,
  });

  factory TrafficHistoryBatch.fromJson(Map<String, dynamic> json) {
    return TrafficHistoryBatch(
      session: json['session'] as String,
      sequence: json['sequence'] as int,
      droppedBytes: json['droppedBytes'] as int? ?? 0,
      records: (json['records'] as List)
          .map(
            (record) => TrafficHistoryRecord.fromJson(
              Map<String, dynamic>.from(record as Map),
            ),
          )
          .toList(),
    );
  }
}

class ApplicationTraffic {
  final String process;
  final String processPath;
  final int upload;
  final int download;

  const ApplicationTraffic({
    required this.process,
    required this.processPath,
    required this.upload,
    required this.download,
  });

  int get total => upload + download;
}
