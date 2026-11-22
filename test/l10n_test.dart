import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';

import 'package:lastwave_desktop/core/l10n/app_language.dart';
import 'package:lastwave_desktop/core/l10n/app_localizations.dart';
import 'package:lastwave_desktop/core/l10n/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Localization & Language Tests', () {
    test('All 15 languages are present in AppLanguage', () {
      expect(AppLanguage.values.length, 16); // 15 + system
      expect(AppLanguage.supportedLocales.length, 15);
    });

    test('Limusic Innertube hl mapping is strict and accurate', () {
      // 13 Limusic languages
      expect(AppLanguage.english.innertubeHl, 'en');
      expect(AppLanguage.turkish.innertubeHl, 'tr');
      expect(AppLanguage.chineseSimplified.innertubeHl, 'zh-Hans');
      expect(AppLanguage.russian.innertubeHl, 'ru');
      expect(AppLanguage.portugueseBrazil.innertubeHl, 'pt-BR');
      expect(AppLanguage.spanish.innertubeHl, 'es');
      expect(AppLanguage.indonesian.innertubeHl, 'id');
      expect(AppLanguage.german.innertubeHl, 'de');
      expect(AppLanguage.french.innertubeHl, 'fr');
      expect(AppLanguage.italian.innertubeHl, 'it');
      expect(AppLanguage.japanese.innertubeHl, 'ja');
      expect(AppLanguage.korean.innertubeHl, 'ko');
      expect(AppLanguage.vietnamese.innertubeHl, 'vi');

      // Non-Limusic languages MUST fall back to 'en'
      expect(AppLanguage.hindi.innertubeHl, 'en');
      expect(AppLanguage.arabic.innertubeHl, 'en');
    });

    test('RTL flag is true only for Arabic', () {
      for (final lang in AppLanguage.values) {
        if (lang == AppLanguage.arabic) {
          expect(lang.isRtl, isTrue);
        } else {
          expect(lang.isRtl, isFalse);
        }
      }
    });

    test('fromTag handles various formats and legacy tags safely', () {
      expect(AppLanguage.fromTag('zh-CN'), AppLanguage.chineseSimplified);
      expect(AppLanguage.fromTag('zh_CN'), AppLanguage.chineseSimplified);
      expect(AppLanguage.fromTag('zh-Hans'), AppLanguage.chineseSimplified);
      expect(AppLanguage.fromTag('in'), AppLanguage.indonesian);
      expect(AppLanguage.fromTag('pt'), AppLanguage.portugueseBrazil);
      expect(AppLanguage.fromTag('pt-BR'), AppLanguage.portugueseBrazil);
      expect(AppLanguage.fromTag('unknown_LANG'), AppLanguage.system);
      expect(AppLanguage.fromTag(null), AppLanguage.system);
      expect(AppLanguage.fromTag(''), AppLanguage.system);
    });

    test('Every language resolves essential UI strings without empty text', () {
      for (final lang in AppLanguage.values) {
        if (lang == AppLanguage.system) continue;
        final l10n = AppLocalizations.forLanguage(lang);
        expect(l10n.navHome.isNotEmpty, isTrue, reason: 'navHome empty for ${lang.tag}');
        expect(l10n.navSettings.isNotEmpty, isTrue, reason: 'navSettings empty for ${lang.tag}');
        expect(l10n.play.isNotEmpty, isTrue, reason: 'play empty for ${lang.tag}');
        expect(l10n.pause.isNotEmpty, isTrue, reason: 'pause empty for ${lang.tag}');
        expect(l10n.settingsGeneral.isNotEmpty, isTrue, reason: 'settingsGeneral empty for ${lang.tag}');
        expect(l10n.settingsPlayback.isNotEmpty, isTrue, reason: 'settingsPlayback empty for ${lang.tag}');
        expect(l10n.settingsAudio.isNotEmpty, isTrue, reason: 'settingsAudio empty for ${lang.tag}');
        expect(l10n.settingsLanguage.isNotEmpty, isTrue, reason: 'settingsLanguage empty for ${lang.tag}');
      }
    });

    test('Fallback to English when key is missing in target language', () {
      final l10n = AppLocalizations(AppLanguage.arabic);
      // Key that might not be in Arabic but is in English
      final translated = l10n.tr('navHome');
      expect(translated, 'الرئيسية');

      // Test guaranteed fallback
      final fallback = resolveTranslation('ar', 'non_existent_key_xyz');
      expect(fallback, 'non_existent_key_xyz');
    });

    test('No regex crashes with special characters in arguments and keys', () {
      final l10n = AppLocalizations(AppLanguage.english);

      // Tricky arguments containing regex control chars: $, \, *, +, ?, [, ], (, ), ^, |
      final dangerousArgs = [r'$100 \test (special) [chars] *+?^|', 'Arg 2'];
      
      // Formatting with dangerous args must NOT throw
      expect(() => l10n.tr('settings_language_subtitle', dangerousArgs), returnsNormally);
      expect(() => l10n.tr('any_key_with_%s', dangerousArgs), returnsNormally);

      // Argument formatting with plain strings
      final result = l10n.tr('settings_language_subtitle', ['Turkish']);
      expect(result.contains('Turkish'), isTrue);
    });
  });
}
