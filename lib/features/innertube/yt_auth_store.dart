import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../core/storage/secure_store.dart';

/// Persisted YouTube session bundle for instant headless boot.
/// Eliminates the need to spawn WebView2 / WebKit on startup.
@immutable
class YtSessionBundle {
  final String cookies;
  final String visitorData;
  final String poToken;
  final DateTime? poTokenExpiresAt;
  final String dataSyncId;
  final String accountType; // 'premium' | 'free' | 'guest'

  const YtSessionBundle({
    this.cookies = '',
    this.visitorData = '',
    this.poToken = '',
    this.poTokenExpiresAt,
    this.dataSyncId = '',
    this.accountType = 'guest',
  });

  bool get isPoTokenStale {
    if (poToken.isEmpty || poTokenExpiresAt == null) return true;
    final cutoff = poTokenExpiresAt!.subtract(const Duration(minutes: 15));
    return DateTime.now().isAfter(cutoff);
  }

  bool get isExpired {
    if (poTokenExpiresAt == null) return true;
    return DateTime.now().isAfter(poTokenExpiresAt!);
  }

  bool get isSignedIn => cookies.isNotEmpty && cookies.contains('SAPISID');
  bool get isPremium => accountType == 'premium';

  YtSessionBundle copyWith({
    String? cookies,
    String? visitorData,
    String? poToken,
    DateTime? poTokenExpiresAt,
    String? dataSyncId,
    String? accountType,
  }) {
    return YtSessionBundle(
      cookies: cookies ?? this.cookies,
      visitorData: visitorData ?? this.visitorData,
      poToken: poToken ?? this.poToken,
      poTokenExpiresAt: poTokenExpiresAt ?? this.poTokenExpiresAt,
      dataSyncId: dataSyncId ?? this.dataSyncId,
      accountType: accountType ?? this.accountType,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'cookies': cookies,
      'visitorData': visitorData,
      'poToken': poToken,
      'poTokenExpiresAt': poTokenExpiresAt?.millisecondsSinceEpoch,
      'dataSyncId': dataSyncId,
      'accountType': accountType,
    };
  }

  factory YtSessionBundle.fromJson(Map<String, dynamic> json) {
    DateTime? expires;
    final expMs = json['poTokenExpiresAt'];
    if (expMs is num && expMs > 0) {
      expires = DateTime.fromMillisecondsSinceEpoch(expMs.toInt());
    }
    return YtSessionBundle(
      cookies: json['cookies']?.toString() ?? '',
      visitorData: json['visitorData']?.toString() ?? '',
      poToken: json['poToken']?.toString() ?? '',
      poTokenExpiresAt: expires,
      dataSyncId: json['dataSyncId']?.toString() ?? '',
      accountType: json['accountType']?.toString() ?? 'guest',
    );
  }
}

/// Disk persistence manager for [YtSessionBundle] backed by [SecureStore].
class YtAuthStore {
  static const String sessionKey = 'yt_session_bundle';
  final SecureStore _secureStore;
  YtSessionBundle? _cached;

  YtAuthStore(this._secureStore);

  YtSessionBundle get current => _cached ?? const YtSessionBundle();

  /// Loads the persisted session bundle into memory on startup.
  Future<YtSessionBundle> load() async {
    try {
      final raw = await _secureStore.read(sessionKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _cached = YtSessionBundle.fromJson(decoded);
          return _cached!;
        }
      }
    } catch (e) {
      debugPrint('YtAuthStore load error: $e');
    }
    _cached = const YtSessionBundle();
    return _cached!;
  }

  /// Persists [bundle] to secure storage.
  Future<void> save(YtSessionBundle bundle) async {
    _cached = bundle;
    try {
      final jsonStr = jsonEncode(bundle.toJson());
      await _secureStore.write(sessionKey, jsonStr);
    } catch (e) {
      debugPrint('YtAuthStore save error: $e');
    }
  }

  /// Updates only the BotGuard PO-Token and its expiration.
  Future<void> updatePoToken({
    required String poToken,
    required DateTime expiresAt,
  }) async {
    final next = current.copyWith(
      poToken: poToken,
      poTokenExpiresAt: expiresAt,
    );
    await save(next);
  }

  /// Updates cookies and rotates jar.
  Future<void> updateCookies(String cookies) async {
    final next = current.copyWith(cookies: cookies);
    await save(next);
  }

  /// Updates visitor data.
  Future<void> updateVisitorData(String visitorData) async {
    final next = current.copyWith(visitorData: visitorData);
    await save(next);
  }

  /// Clears stored session bundle on sign out.
  Future<void> clear() async {
    _cached = const YtSessionBundle();
    try {
      await _secureStore.delete(sessionKey);
    } catch (_) {}
  }
}
