import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final trafficHistoryStoreProvider = Provider<TrafficHistoryDao>((ref) {
  return database.trafficHistoryDao;
});

final trafficHistoryProvider = Provider<TrafficHistoryRecorder>((ref) {
  final recorder = TrafficHistoryRecorder(
    core: ref.read(coreHandlerProvider),
    store: ref.read(trafficHistoryStoreProvider),
    connected: () => ref.read(coreStatusProvider) == CoreStatus.connected,
  );
  ref.onDispose(recorder.dispose);
  return recorder;
});

class TrafficHistoryRecorder {
  final CoreController core;
  final TrafficHistoryDao store;
  final bool Function() connected;
  Timer? _timer;
  Future<void>? _operation;
  String _session = '';
  int _sequence = 0;
  bool _disposed = false;

  TrafficHistoryRecorder({
    required this.core,
    required this.store,
    required this.connected,
  });

  void start() {
    if (_timer != null || _disposed) return;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(synchronizeSafely());
    });
  }

  Future<void> synchronizeSafely() async {
    try {
      await synchronize();
    } catch (error) {
      commonPrint.log(
        'Traffic history persistence failed: $error',
        logLevel: LogLevel.warning,
      );
    }
  }

  Future<void> synchronize({bool flush = false}) {
    if (_disposed || !connected()) return Future.value();
    return _operation ??= _synchronize(
      flush: flush,
    ).whenComplete(() => _operation = null);
  }

  Future<void> flushSafely() async {
    try {
      await _flush().timeout(const Duration(seconds: 1));
    } catch (error) {
      commonPrint.log(
        'Traffic history final flush failed: $error',
        logLevel: LogLevel.warning,
      );
    }
  }

  Future<void> _flush() async {
    final active = _operation;
    if (active != null) await active;
    await synchronize(flush: true);
  }

  Future<void> _synchronize({required bool flush}) async {
    for (var page = 0; page < 16; page++) {
      final batch = await core.getTrafficHistory(
        session: _session,
        sequence: _sequence,
        flush: flush,
      );
      await store.saveBatch(batch);
      _session = batch.session;
      _sequence = batch.sequence;
      if (_disposed ||
          (flush ? batch.records.isEmpty : batch.records.length < 256)) {
        return;
      }
    }
  }

  void dispose() {
    _disposed = true;
    stop();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
