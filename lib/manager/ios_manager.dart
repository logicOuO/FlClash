import 'dart:async';

import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class IOSManager extends ConsumerStatefulWidget {
  final Widget child;

  const IOSManager({super.key, required this.child});

  @override
  ConsumerState<IOSManager> createState() => _IOSManagerState();
}

class _IOSManagerState extends ConsumerState<IOSManager>
    with WidgetsBindingObserver, ServiceListener {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    service?.addListener(this);
    ref.listenManual(sharedStateProvider, (previous, next) {
      if (previous?.needSyncSharedState != next.needSyncSharedState) {
        unawaited(service?.syncState(next.needSyncSharedState));
      }
    });
  }

  @override
  void onServiceEvent(CoreEvent event) => coreEventManager.sendEvent(event);

  @override
  void onServiceStatus(DateTime? startedAt) {
    ref.read(setupActionProvider.notifier).synchronizeServiceRuntime(startedAt);
    if (startedAt != null) {
      final core = ref.read(coreHandlerProvider);
      if (ref.read(appSettingProvider).openLogs) {
        core.startLog();
      } else {
        core.stopLog();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final startedAt = await service?.getRunTime();
    if (mounted) onServiceStatus(startedAt);
  }

  @override
  void dispose() {
    service?.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
