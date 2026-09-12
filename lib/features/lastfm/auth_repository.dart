import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/env/app_env.dart';
import '../../core/network/dio_factory.dart';
import '../../core/network/lastfm_api.dart';
import '../../core/network/lastfm_crypto.dart';
import '../../core/network/rate_guard.dart';
import '../../core/storage/prefs.dart';
import '../../core/storage/secure_store.dart';

/// Last.fm authentication state. Mirrors Android `AuthState`.
enum AuthStatus { unknown, signedOut, signingIn, signedIn, error }

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
    } else {
      state = const AuthState(status: AuthStatus.signedOut);
    }
  }

  /// Last.fm API credentials — always the app keys from .env
  /// (same as LastWave-native). Users only OAuth; no custom keys.
  String get _apiKey => AppEnv.lastfmApiKey;
  String get _apiSecret => AppEnv.lastfmApiSecret;

  /// Step 1 of web auth: fetch a token and build the approval URL.
  Future<WebAuthHandshake> beginWebAuth() async {
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
