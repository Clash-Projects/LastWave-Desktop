import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_language.dart';
import 'translations.dart';

/// Centralized localization instance for LastWave Desktop.
///
/// Provides strongly-typed getters for primary UI strings as well as
/// [tr] for generic string lookups with arguments.
class AppLocalizations {
  final AppLanguage language;

  const AppLocalizations(this.language);

  static AppLocalizations _current =
      const AppLocalizations(AppLanguage.english);

  /// Synchronous fallback accessor for non-widget contexts.
  static AppLocalizations get current => _current;

  /// Sets the active global instance.
  static void setCurrent(AppLocalizations l10n) {
    _current = l10n;
  }

  /// Obtains the [AppLocalizations] from the given [context].
  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        _current;
  }

  /// Factory from a Flutter [Locale].
  factory AppLocalizations.fromLocale(Locale locale) {
    final tag = locale.countryCode != null && locale.countryCode!.isNotEmpty
        ? '${locale.languageCode}-${locale.countryCode}'
        : locale.languageCode;
    final lang = AppLanguage.fromTag(tag);
    return AppLocalizations(lang);
  }

  /// Factory for an explicit [AppLanguage].
  factory AppLocalizations.forLanguage(AppLanguage lang) {
    return AppLocalizations(lang.effectiveLanguage);
  }

  /// Translates [key] using the active language catalog.
  /// Strictly falls back to original English US ('en') if lookup or formatting fails.
  /// Uses pure literal string matching with zero regex compilation to guarantee no regex crashes.
  String tr(String key, [List<Object>? args]) {
    try {
      var text = resolveTranslation(language.tag, key);
      if (args == null || args.isEmpty) return text;

      // Pure literal string replacements (zero RegExp compilation, immune to regex crashes)
      for (var i = 0; i < args.length; i++) {
        final argStr = args[i].toString();
        text = text
            .replaceAll('%${i + 1}\$s', argStr)
            .replaceAll('{$i}', argStr);
      }
      if (args.isNotEmpty) {
        text = text.replaceFirst('%s', args[0].toString());
      }
      return text;
    } catch (_) {
      // Guaranteed safe fallback to original English US
      try {
        var fallbackText = resolveTranslation('en', key);
        if (args != null && args.isNotEmpty) {
          for (var i = 0; i < args.length; i++) {
            final argStr = args[i].toString();
            fallbackText = fallbackText
                .replaceAll('%${i + 1}\$s', argStr)
                .replaceAll('{$i}', argStr);
          }
          fallbackText = fallbackText.replaceFirst('%s', args[0].toString());
        }
        return fallbackText;
      } catch (_) {
        return key;
      }
    }
  }

  // -- Navigation -----------------------------------------------------------
  String get navHome => tr('navHome');
  String get navStats => tr('navStats');
  String get navSearch => tr('navSearch');
  String get navPodcasts => tr('navPodcasts');
  String get navPlaylists => tr('navPlaylists');
  String get navLibrary => tr('navLibrary');
  String get navJam => tr('navJam');
  String get navSettings => tr('navSettings');

  // -- Settings Sections ----------------------------------------------------
  String get settingsSound => tr('settingsSound');
  String get settingsDisplay => tr('settingsDisplay');
  String get settingsGeneral => tr('settingsGeneral');
  String get settingsPlayback => tr('settingsPlayback');
  String get settingsAudio => tr('settingsAudio');
  String get settingsDownloads => tr('settingsDownloads');
  String get settingsLibrary => tr('settingsLibrary');
  String get settingsLyrics => tr('settingsLyrics');
  String get settingsAppearance => tr('settingsAppearance');
  String get settingsScrobbler => tr('settingsScrobbler');
  String get settingsIntegrations => tr('settingsIntegrations');
  String get settingsSources => tr('settingsSources');
  String get settingsServices => tr('settingsServices');
  String get settingsExperimental => tr('settingsExperimental');
  String get settingsAbout => tr('settingsAbout');

  // -- Settings Items -------------------------------------------------------
  String get settingsBehaviour => tr('settingsBehaviour');
  String get settingsBehaviourSub => tr('settingsBehaviourSub');
  String get settingsCloseToTray => tr('settingsCloseToTray');
  String get settingsCloseToTraySub => tr('settingsCloseToTraySub');
  String get settingsMiniplayerStyle => tr('settingsMiniplayerStyle');
  String get settingsLanguage => tr('settingsLanguage');
  String get settingsLanguageSub => tr('settingsLanguageSub');
  String get settingsBackup => tr('settingsBackup');
  String get settingsBackupSub => tr('settingsBackupSub');

  // -- Player Controls ------------------------------------------------------
  String get play => tr('play');
  String get pause => tr('pause');
  String get next => tr('next');
  String get previous => tr('previous');
  String get shuffle => tr('shuffle');
  String get repeat => tr('repeat');
  String get volume => tr('volume');
  String get mute => tr('mute');
  String get queue => tr('queue');
  String get lyrics => tr('lyrics');

  // -- Common Actions -------------------------------------------------------
  String get cancel => tr('cancel');
  String get save => tr('save');
  String get done => tr('done');
  String get delete => tr('delete');
  String get close => tr('close');
  String get loading => tr('loading');
  String get noResults => tr('noResults');

  // Performance Mode
  String get performanceMode => tr('performance_mode');
  String get performanceModeDescOn => tr('performance_mode_desc_on');
  String get performanceModeDescOff => tr('performance_mode_desc_off');
  String get performanceModeRecommended => tr('performance_mode_recommended');
  String get performanceModeWhyLagTitle => tr('performance_mode_why_lag_title');
  String get performanceModeWhyLagBody => tr('performance_mode_why_lag_body');
  String get performanceModeOptimizationsActive => tr('performance_mode_optimizations_active');
  String get performanceModeOptimizationsActiveSub => tr('performance_mode_optimizations_active_sub');
  String get performanceModeOptimizationsPlanned => tr('performance_mode_optimizations_planned');
  String get performanceModeOptimizationsPlannedSub => tr('performance_mode_optimizations_planned_sub');
  String get performanceModeManagedTag => tr('performance_mode_managed_tag');
  String get performanceModeConflictTitle => tr('performance_mode_conflict_title');
  String get performanceModeConflictBody => tr('performance_mode_conflict_body');
  String get performanceModeConflictConfirm => tr('performance_mode_conflict_confirm');
  String get performanceModeConflictCancel => tr('performance_mode_conflict_cancel');

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) {
    final l10n = AppLocalizations.fromLocale(locale);
    AppLocalizations.setCurrent(l10n);
    return SynchronousFuture<AppLocalizations>(l10n);
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
