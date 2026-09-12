import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/env/app_env.dart';
import '../../core/storage/app_database.dart';

/// Shared providers to avoid import cycles.
final databaseProvider = Provider<AppDatabase>((_) {
  throw UnimplementedError('Database not initialised — override in main()');
});

/// Last.fm API key — always from .env (same keys as LastWave-native).
final prefsApiKeyProvider = Provider<String>((_) {
  return AppEnv.lastfmApiKey;
});
