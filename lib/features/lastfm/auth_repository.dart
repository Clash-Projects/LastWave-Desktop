import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/dio_factory.dart';
import '../../core/network/lastfm_api.dart';
import '../../core/network/lastfm_crypto.dart';
import '../../core/network/rate_guard.dart';
import '../../core/storage/prefs.dart';
import '../../core/storage/secure_store.dart';

/// Last.fm authentication state. Mirrors Android `AuthState`.
/// `guest` = keyless entry via the welcome Skip button: inside the
/// shell with no keys and no session; Last.fm features stay off.
enum AuthStatus { unknown, signedOut, signingIn, signedIn, guest, error }

class AuthState {
  final AuthStatus status;
  final String username;
  final String message;
  const AuthState({
    this.status = AuthStatus.unknown,
    this.username = '',
    this.message = '',
  });

  AuthState copyWith({
    AuthStatus? status,
    String? username,
    String? message,
  }) =>
      AuthState(
        status: status ?? this.status,
        username: username ?? this.username,
        message: message ?? this.message,
      );
}

/// Pending web-auth handshake (token obtained, awaiting approval).
class WebAuthHandshake {
  final String token;
  final String url;
  const WebAuthHandshake(this.token, this.url);
}

/// Last.fm auth repository.
///
/// Ported from LastWave-native `data/repository/AuthRepository.kt`:
/// - web auth via `https://www.last.fm/api/auth/?api_key=..&cb=..`
/// - `auth.getToken` / `auth.getSession` exchange
/// - direct credential sign-in verification via `user.getinfo`
/// - sign-out preserving API credentials
class AuthRepository extends StateNotifier<AuthState> {
  final LastFmApiService _api;
  final Prefs _prefs;
  final SecureStore _secure;

  AuthRepository(this._api, this._prefs, this._secure)
      : super(const AuthState()) {
    _restore();
  }

  void _restore() {
    if (_prefs.username.isNotEmpty) {
      state = AuthState(
        status: AuthStatus.signedIn,
        username: _prefs.username,
      );
    } else if (_prefs.isGuest) {
      state = const AuthState(status: AuthStatus.guest);
    } else {
      state = const AuthState(status: AuthStatus.signedOut);
    }
  }

  /// Keyless entry: enter the shell without Last.fm keys or session.
  /// Sticky via Prefs; cleared by full sign-out and by real sessions.
  Future<void> enterGuestMode() async {
    await _prefs.setGuestMode(true);
    state = const AuthState(status: AuthStatus.guest);
  }

  /// Last.fm API credentials — the user's own keys (BYOK), stored in
  /// Prefs. Empty until the user enters them (Settings / welcome).
  String get _apiKey => _prefs.lastFmApiKey;
  String get _apiSecret => _prefs.lastFmApiSecret;

  /// True when custom API keys are present. Web auth and all signed
  /// calls require this; repositories no-op otherwise.
  bool get isConfigured => _prefs.isLastFmConfigured;

  /// Save user-supplied API keys (Settings / welcome share this path).
  ///
  /// Session keys are bound to the API key that minted them, so saving
  /// *different* keys signs the current session out first. The
  /// candidate keys are validated with a signed `auth.getToken` call
  /// (wrong secret fails the signature check) and persisted only on
  /// success.
  Future<void> saveCustomKeys(String apiKey, String apiSecret) async {
    final key = apiKey.trim();
    final secret = apiSecret.trim();
    if (key.isEmpty || secret.isEmpty) {
      state = state.copyWith(
        status: AuthStatus.error,
        message: 'Enter both the API key and the shared secret.',
      );
      throw LastFmException('Incomplete Last.fm API keys');
    }
    if (key != _prefs.lastFmApiKey || secret != _prefs.lastFmApiSecret) {
      // Sessions belong to their API key — clear any session. Guests
      // stay guests (no welcome bounce mid-save); signed-in users
      // drop to signedOut and reconnect via welcome.
      final wasGuest = _prefs.isGuest;
      await _prefs.signOut();
      await _secure.writeSessionKey(null);
      state = AuthState(
        status: wasGuest ? AuthStatus.guest : AuthStatus.signedOut,
      );
      if (wasGuest) await _prefs.setGuestMode(true);
    }
    state = state.copyWith(status: AuthStatus.signingIn);
    try {
      final params = {'method': 'auth.getToken', 'api_key': key};
      final signed = {
        ...params,
        'api_sig': LastFmSigner.sign(params, secret),
        'format': 'json',
      };
      final json = await _api.get(signed);
      LastFmException.throwIfError(json);
      if ((json['token']?.toString() ?? '').isEmpty) {
        throw LastFmException('Last.fm rejected these API keys');
      }
      await _prefs.saveLastFmKeys(apiKey: key, apiSecret: secret);
      state = const AuthState(status: AuthStatus.signedOut);
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.error,
        message: e.toString(),
      );
      rethrow;
    }
  }

  /// Clear the custom API keys (Settings). Also signs out: sessions
  /// cannot survive without keys.
  Future<void> clearCustomKeys() async {
    await signOut();
    await _prefs.clearLastFmKeys();
  }

  /// Step 1 of web auth: fetch a token and build the approval URL.
  Future<WebAuthHandshake> beginWebAuth() async {
    if (!isConfigured) {
      state = state.copyWith(
        status: AuthStatus.error,
        message: 'Enter your Last.fm API keys first.',
      );
      throw LastFmException('Last.fm API keys not set');
    }
    state = state.copyWith(status: AuthStatus.signingIn);
    final params = {'method': 'auth.getToken', 'api_key': _apiKey};
    final signed = {
      ...params,
      'api_sig': LastFmSigner.sign(params, _apiSecret),
      'format': 'json',
    };
    final json = await _api.get(signed);
    LastFmException.throwIfError(json);
    final token = json['token']?.toString() ?? '';
    if (token.isEmpty) {
      state = state.copyWith(
        status: AuthStatus.error,
        message: 'Could not start Last.fm approval.',
      );
      throw LastFmException('Empty auth token');
    }
    final url =
        'https://www.last.fm/api/auth/?api_key=$_apiKey&token=$token';
    return WebAuthHandshake(token, url);
  }

  /// Step 2: exchange the approved token for a session key.
  Future<void> completeWebAuth(String token) async {
    try {
      final params = {
        'method': 'auth.getSession',
        'api_key': _apiKey,
        'token': token,
      };
      final signed = {
        ...params,
        'api_sig': LastFmSigner.sign(params, _apiSecret),
        'format': 'json',
      };
      final json = await _api.get(signed);
      LastFmException.throwIfError(json);
      final session = json['session'] as Map<String, dynamic>?;
      final key = session?['key']?.toString() ?? '';
      final name = session?['name']?.toString() ?? '';
      if (key.isEmpty || name.isEmpty) {
        throw LastFmException('Approval not completed yet');
      }
      await _prefs.saveSession(
        sessionKey: key,
        username: name,
      );
      await _secure.writeSessionKey(key);
      state = AuthState(
        status: AuthStatus.signedIn,
        username: name,
      );
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.error,
        message: e.toString(),
      );
      rethrow;
    }
  }

  Future<void> signOut() async {
    await _prefs.signOut();
    await _prefs.setGuestMode(false);
    await _secure.writeSessionKey(null);
    state = const AuthState(status: AuthStatus.signedOut);
  }

  void clearError() {
    if (state.status == AuthStatus.error) {
      state = state.copyWith(
        status: _prefs.username.isEmpty
            ? AuthStatus.signedOut
            : AuthStatus.signedIn,
        message: '',
      );
    }
  }
}

final authRepositoryProvider =
    StateNotifierProvider<AuthRepository, AuthState>((ref) {
  final dio = DioFactory.create(rateGuard: LastFmRateGuard());
  dio.options.baseUrl = LastFmApiService.baseUrl;
  final api = LastFmApiService(dio, LastFmRateGuard());
  return AuthRepository(
    api,
    ref.watch(prefsProvider),
    ref.watch(secureStoreProvider),
  );
});

/// Shared Last.fm API provider for repositories.
final lastFmApiProvider = Provider<LastFmApiService>((ref) {
  final dio = DioFactory.create(rateGuard: LastFmRateGuard());
  dio.options.baseUrl = LastFmApiService.baseUrl;
  return LastFmApiService(dio, LastFmRateGuard());
});
