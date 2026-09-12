import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../design_system/theme.dart';
import 'theme_controller.dart';

/// LastWave desktop application root.
class LastWaveApp extends ConsumerStatefulWidget {
  const LastWaveApp({super.key});
  @override
  ConsumerState<LastWaveApp> createState() =>
      _LastWaveAppState();
}

class _LastWaveAppState
    extends ConsumerState<LastWaveApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = buildRouter();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeControllerProvider);
    return MaterialApp.router(
      title: 'LastWave',
      debugShowCheckedModeBanner: false,
      theme: buildLastWaveTheme(
        accent: theme.accent,
        amoled: theme.amoled,
      ),
      themeMode: ThemeMode.dark,
      routerConfig: _router,
    );
  }
}
