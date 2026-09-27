import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';

/// Shared providers to avoid import cycles.
final databaseProvider = Provider<AppDatabase>((_) {
  throw UnimplementedError('Database not initialised — override in main()');
});

/// Last.fm API key — the user's own key (BYOK, stored in Prefs).
/// Empty until the user enters keys (Settings / welcome).
final prefsApiKeyProvider = Provider<String>((ref) {
  return ref.watch(prefsProvider).lastFmApiKey;
});
