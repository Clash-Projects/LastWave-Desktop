import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/search/search_page.dart';

/// Legacy Material search screen — thin shim over [WaveSearchPage].
///
/// The editorial ledger experiment (filter tabs + boxed suggestions) is
/// retired: all search UX lives in the Fluent [WaveSearchPage] (Top Result
/// + table songs + card rails) backed by keepAlive section providers.
/// Kept only so old imports keep compiling.
@Deprecated('Use WaveSearchPage from ui/search/search_page.dart instead.')
class SearchScreen extends ConsumerWidget {
  final String initialQuery;
  const SearchScreen({super.key, this.initialQuery = ''});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return WaveSearchPage(initialQuery: initialQuery);
  }
}
