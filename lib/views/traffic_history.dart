import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/common.dart';
import 'package:fl_clash/models/traffic_history.dart';
import 'package:fl_clash/providers/traffic_history.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class TrafficHistoryView extends ConsumerStatefulWidget {
  final DateTime Function()? now;

  const TrafficHistoryView({super.key, @visibleForTesting this.now});

  @override
  ConsumerState<TrafficHistoryView> createState() => _TrafficHistoryViewState();
}

class _TrafficHistoryViewState extends ConsumerState<TrafficHistoryView> {
  late DateTime _start;
  late DateTime _end;
  late Stream<List<ApplicationTraffic>> _usage;
  late Stream<int> _droppedBytes;
  bool _proxy = true;
  bool _refreshing = false;
  String _query = '';
  int? _presetDays = 0;
  Timer? _midnightTimer;

  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _setPreset(0);
    _droppedBytes = ref.read(trafficHistoryStoreProvider).watchDroppedBytes();
    _scheduleMidnight();
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    super.dispose();
  }

  void _scheduleMidnight() {
    final now = _now;
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnightTimer = Timer(next.difference(now), () {
      if (!mounted) return;
      if (_presetDays != null) setState(_refreshRange);
      _scheduleMidnight();
    });
  }

  void _refreshRange() {
    final days = _presetDays;
    if (days == null) {
      _watchUsage();
    } else {
      _setPreset(days);
    }
  }

  void _watchUsage() {
    _usage = ref
        .read(trafficHistoryStoreProvider)
        .watchUsage(start: _start, end: _end, proxy: _proxy);
  }

  void _setPreset(int days) {
    _presetDays = days;
    final now = _now;
    final today = DateTime(now.year, now.month, now.day);
    _start = DateTime(today.year, today.month, today.day - days);
    _end = days == 1 ? today : DateTime(today.year, today.month, today.day + 1);
    _watchUsage();
  }

  Future<void> _pickBoundary(bool start) async {
    final initial = start ? _start : _end;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(_now.year + 1),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final value = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final nextStart = start ? value : _start;
    final nextEnd = start ? _end : value;
    if (!nextStart.isBefore(nextEnd)) {
      context.showNotifier(context.appLocalizations.trafficHistoryInvalidRange);
      return;
    }
    setState(() {
      _start = nextStart;
      _end = nextEnd;
      _presetDays = null;
      _watchUsage();
    });
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await ref.read(trafficHistoryProvider).synchronize();
      if (mounted) setState(_refreshRange);
    } catch (error) {
      if (mounted) {
        context.showNotifier(context.appLocalizations.trafficHistorySyncFailed);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Widget _buildFilters(BuildContext context) {
    final labels = context.appLocalizations;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                label: Text(labels.trafficHistoryToday),
                onPressed: () => setState(() => _setPreset(0)),
              ),
              ActionChip(
                label: Text(labels.trafficHistoryYesterday),
                onPressed: () => setState(() => _setPreset(1)),
              ),
              ActionChip(
                label: Text(labels.trafficHistoryLastSevenDays),
                onPressed: () => setState(() => _setPreset(6)),
              ),
              FilterChip(
                label: Text(labels.trafficHistoryProxy),
                selected: _proxy,
                onSelected: (_) => setState(() {
                  _proxy = true;
                  _watchUsage();
                }),
              ),
              FilterChip(
                label: Text(labels.direct),
                selected: !_proxy,
                onSelected: (_) => setState(() {
                  _proxy = false;
                  _watchUsage();
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => _pickBoundary(true),
                icon: const Icon(Icons.calendar_today),
                label: Text('${labels.trafficHistoryFrom}: ${_start.showFull}'),
              ),
              TextButton.icon(
                onPressed: () => _pickBoundary(false),
                icon: const Icon(Icons.event),
                label: Text('${labels.trafficHistoryUntil}: ${_end.showFull}'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: InputDecoration(
              labelText: labels.search,
              prefixIcon: const Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _query = value.toLowerCase()),
          ),
          const SizedBox(height: 8),
          Text(
            labels.trafficHistoryHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          StreamBuilder<int>(
            stream: _droppedBytes,
            builder: (context, snapshot) => (snapshot.data ?? 0) == 0
                ? const SizedBox.shrink()
                : Text(
                    labels.trafficHistoryIncomplete(
                      snapshot.data!.traffic.show,
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, ApplicationTraffic row) {
    final labels = context.appLocalizations;
    final name = row.process.isNotEmpty
        ? row.process
        : row.processPath.isNotEmpty && !row.processPath.startsWith('source://')
        ? row.processPath.split(RegExp(r'[/\\]')).last
        : labels.unknown;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.apps),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Tooltip(
          message: row.processPath.isEmpty ? labels.unknown : row.processPath,
          child: Text(
            '${row.processPath.isEmpty ? labels.unknown : row.processPath}\n'
            '↑ ${row.upload.traffic.show}  ↓ ${row.download.traffic.show}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        isThreeLine: true,
        trailing: Text(row.total.traffic.show),
      ),
    );
  }

  Widget _buildUsage(BuildContext context) {
    final labels = context.appLocalizations;
    return StreamBuilder<List<ApplicationTraffic>>(
      stream: _usage,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text(labels.trafficHistoryReadFailed)),
          );
        }
        if (!snapshot.hasData ||
            snapshot.connectionState == ConnectionState.waiting) {
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final all = snapshot.data!;
        final rows = all
            .where(
              (row) =>
                  row.process.toLowerCase().contains(_query) ||
                  row.processPath.toLowerCase().contains(_query),
            )
            .toList();
        final upload = all.fold<int>(0, (total, row) => total + row.upload);
        final download = all.fold<int>(0, (total, row) => total + row.download);
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  '${labels.totalTraffic}: ${(upload + download).traffic.show}  ·  '
                  '↑ ${upload.traffic.show}  ↓ ${download.traffic.show}',
                ),
              ),
            ),
            if (rows.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text(labels.noData)),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) =>
                      _buildRow(context, rows[index]),
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    return CommonScaffold(
      title: labels.trafficHistory,
      actions: [
        IconButton(
          tooltip: labels.trafficHistoryRefresh,
          onPressed: _refreshing ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildFilters(context)),
          _buildUsage(context),
        ],
      ),
    );
  }
}
