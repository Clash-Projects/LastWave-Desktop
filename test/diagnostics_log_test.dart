import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/diagnostics/diagnostics_log.dart';
import 'package:lastwave_desktop/core/diagnostics/log_bundle.dart';

/// The diagnostics trail is the only thing a user can hand us from a
/// release build, so its two promises are pinned here: it keeps a bounded
/// history across restarts, and whatever it writes can be shared without
/// leaking a credential.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lw_diag_test');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('DiagnosticsLog', () {
    test('opens a session file and honours the verbose level', () {
      DiagnosticsLog.init(dir, verbose: false);
      DiagnosticsLog.info('always-on line');
      DiagnosticsLog.detail('per-request line');

      final file = DiagnosticsLog.file;
      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);

      final text = file.readAsStringSync();
      expect(text, contains('session start'));
      expect(text, contains('always-on line'));
      expect(text, isNot(contains('per-request line')));

      DiagnosticsLog.verbose = true;
      DiagnosticsLog.detail('per-request line');
      expect(file.readAsStringSync(), contains('per-request line'));
    });

    test('rotation opens a new file past the size cap', () {
      DiagnosticsLog.init(dir, verbose: false);
      DiagnosticsLog.info('x' * DiagnosticsLog.maxBytesPerFile);
      DiagnosticsLog.info('after rotation');

      final files = DiagnosticsLog.sessionFiles();
      expect(files.length, 2);
      // Newest first: the rotated file carries the post-cap line.
      expect(files.first.readAsStringSync(), contains('after rotation'));
      expect(files.last.readAsStringSync(), isNot(contains('after rotation')));
    });

    test('retention keeps five files and drops the oldest', () {
      // Six historical runs, dated before today so pruning sorts them out
      // first (files are ordered by name, i.e. by boot stamp).
      for (var i = 0; i < 6; i++) {
        File('${dir.path}${Platform.pathSeparator}'
                'session-2020010${i + 1}-120000.log')
            .writeAsStringSync('old run $i\n');
      }
      DiagnosticsLog.init(dir);

      final files = DiagnosticsLog.sessionFiles();
      expect(files.length, DiagnosticsLog.maxFiles);
      expect(files.map((f) => f.path), isNot(contains(endsWith('20200101-120000.log'))));
      // The run that just started is still the newest.
      expect(files.first.path, DiagnosticsLog.file!.path);
    });

    test('an unclean previous run is reported, a clean exit clears it', () {
      DiagnosticsLog.init(dir);
      DiagnosticsLog.info('run one');
      expect(DiagnosticsLog.previousExitClean, isTrue, reason: 'fresh dir');

      // Simulated restart: the previous file has no exit marker.
      DiagnosticsLog.init(dir);
      expect(DiagnosticsLog.previousExitClean, isFalse);

      DiagnosticsLog.markCleanExit();
      DiagnosticsLog.init(dir);
      expect(DiagnosticsLog.previousExitClean, isTrue);
    });
  });

  group('LogBundle', () {
    test('redact strips urls and credentials but keeps track names', () {
      const sample = 'open key=sun raha hai|anurag\n'
          'stream url=https://rr1.googlevideo.com/videoplayback?sig=abc123\n'
          'Cookie: SID=secret-value\n'
          'resolve stage=miss album=Superstar\n';

      final out = LogBundle.redact(sample);
      expect(out, isNot(contains('https://')));
      expect(out, contains('<url>'));
      expect(out, isNot(contains('secret-value')));
      expect(out, isNot(contains('abc123')));
      expect(out, contains('<redacted>'));
      expect(out, contains('sun raha hai|anurag'));
      expect(out, contains('album=Superstar'));
    });

    test('collect ships the session log, the report and the readme', () {
      DiagnosticsLog.init(dir);
      DiagnosticsLog.info('collect me');

      final files = LogBundle.collect(report: 'version: test\n');
      final logKeys = files.keys.where((k) => k.startsWith('logs/')).toList();

      expect(logKeys, isNotEmpty);
      expect(files[logKeys.first], contains('collect me'));
      expect(files['diagnostics.txt'], contains('version: test'));
      expect(files['README.txt'], contains('diagnostics bundle'));
      // Nothing in the bundle may carry a live URL.
      for (final content in files.values) {
        expect(content, isNot(contains('http://')));
        expect(content, isNot(contains('https://')));
      }
    });

    test('build produces a zip archive', () {
      DiagnosticsLog.init(dir);
      DiagnosticsLog.info('zip me');

      final bytes = LogBundle.build(report: 'version: test\n');
      expect(bytes.length, greaterThan(100));
      expect(bytes[0], 0x50); // 'P'
      expect(bytes[1], 0x4b); // 'K'
    });

    test('suggested name is timestamped and zip-suffixed', () {
      final name = LogBundle.suggestedName(DateTime(2026, 10, 23, 17, 5, 9));
      expect(name, 'LastWave-logs-20261023-170509.zip');
    });
  });
}
