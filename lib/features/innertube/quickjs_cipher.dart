import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

// Native FFI typedefs
typedef _PreprocessC = Pointer<Utf8> Function(Pointer<Utf8> baseJs);
typedef _PreprocessDart = Pointer<Utf8> Function(Pointer<Utf8> baseJs);

typedef _SolveC = Pointer<Utf8> Function(
  Pointer<Utf8> preprocessed,
  Pointer<Utf8> n,
  Pointer<Utf8> sig,
);
typedef _SolveDart = Pointer<Utf8> Function(
  Pointer<Utf8> preprocessed,
  Pointer<Utf8> n,
  Pointer<Utf8> sig,
);

typedef _SolveBytecodeC = Pointer<Utf8> Function(
  Pointer<Uint8> bcPtr,
  IntPtr bcLen,
  Pointer<Utf8> n,
  Pointer<Utf8> sig,
);
typedef _SolveBytecodeDart = Pointer<Utf8> Function(
  Pointer<Uint8> bcPtr,
  int bcLen,
  Pointer<Utf8> n,
  Pointer<Utf8> sig,
);

typedef _CompileC = Pointer<Uint8> Function(
  Pointer<Utf8> preprocessed,
  Pointer<IntPtr> outLen,
);
typedef _CompileDart = Pointer<Uint8> Function(
  Pointer<Utf8> preprocessed,
  Pointer<IntPtr> outLen,
);

typedef _FreeStringC = Void Function(Pointer<Utf8> ptr);
typedef _FreeStringDart = void Function(Pointer<Utf8> ptr);

typedef _FreeBytesC = Void Function(Pointer<Uint8> ptr, IntPtr len);
typedef _FreeBytesDart = void Function(Pointer<Uint8> ptr, int len);

class QuickJsPlayer {
  final String id;
  final int sts;
  final Uint8List bytecode;
  final String? preprocessedJs;

  const QuickJsPlayer({
    required this.id,
    required this.sts,
    required this.bytecode,
    this.preprocessedJs,
  });
}

class QuickJsSolveResult {
  final String? n;
  final String? sig;

  const QuickJsSolveResult({this.n, this.sig});
}

/// In-process QuickJS cipher solver binding yt-dlp EJS solver.
/// Replaces NewPipe regex patterns with native QuickJS execution (parity with ytm-rs).
class QuickJsCipher {
  static DynamicLibrary? _lib;
  static bool _initFailed = false;

  static _PreprocessDart? _preprocess;
  static _SolveDart? _solve;
  static _SolveBytecodeDart? _solveBytecode;
  static _CompileDart? _compile;
  static _FreeStringDart? _freeString;
  static _FreeBytesDart? _freeBytes;

  static bool get isAvailable {
    if (_lib != null) return true;
    if (_initFailed) return false;
    return _ensureLoaded();
  }

  static bool _ensureLoaded() {
    if (_lib != null) return true;
    if (_initFailed) return false;

    final candidates = <String>[
      'quickjs_cipher.dll',
      p.join(Directory.current.path, 'quickjs_cipher.dll'),
      p.join(Directory.current.path, 'windows', 'quickjs_cipher.dll'),
      p.join(Directory.current.path, 'windows', 'runner', 'quickjs_cipher.dll'),
      p.join(Directory.current.path, 'assets', 'native', 'windows', 'quickjs_cipher.dll'),
      p.join(p.dirname(Platform.resolvedExecutable), 'quickjs_cipher.dll'),
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        try {
          _lib = DynamicLibrary.open(path);
          _bindSymbols(_lib!);
          return true;
        } catch (e) {
          debugPrint('Failed to load QuickJS from $path: $e');
        }
      }
    }

    try {
      _lib = DynamicLibrary.open('quickjs_cipher.dll');
      _bindSymbols(_lib!);
      return true;
    } catch (_) {
      _initFailed = true;
      return false;
    }
  }

  static void _bindSymbols(DynamicLibrary lib) {
    _preprocess = lib
        .lookup<NativeFunction<_PreprocessC>>('quickjs_cipher_preprocess')
        .asFunction();
    _solve = lib
        .lookup<NativeFunction<_SolveC>>('quickjs_cipher_solve')
        .asFunction();
    _solveBytecode = lib
        .lookup<NativeFunction<_SolveBytecodeC>>('quickjs_cipher_solve_bytecode')
        .asFunction();
    _compile = lib
        .lookup<NativeFunction<_CompileC>>('quickjs_cipher_compile')
        .asFunction();
    _freeString = lib
        .lookup<NativeFunction<_FreeStringC>>('quickjs_cipher_free_string')
        .asFunction();
    _freeBytes = lib
        .lookup<NativeFunction<_FreeBytesC>>('quickjs_cipher_free_bytes')
        .asFunction();
  }

  /// Preprocesses `base.js` with yt-dlp EJS solver.
  static String? preprocess(String baseJs) {
    if (!isAvailable || _preprocess == null || _freeString == null) return null;
    final basePtr = baseJs.toNativeUtf8();
    try {
      final outPtr = _preprocess!(basePtr);
      if (outPtr.address == 0) return null;
      try {
        return outPtr.toDartString();
      } finally {
        _freeString!(outPtr);
      }
    } finally {
      malloc.free(basePtr);
    }
  }

  /// Compiles preprocessed solver JS to QuickJS bytecode.
  static Uint8List? compile(String preprocessedJs) {
    if (!isAvailable || _compile == null || _freeBytes == null) return null;
    final prePtr = preprocessedJs.toNativeUtf8();
    final outLenPtr = malloc<IntPtr>();
    try {
      final bcPtr = _compile!(prePtr, outLenPtr);
      final len = outLenPtr.value;
      if (bcPtr.address == 0 || len == 0) return null;
      try {
        return Uint8List.fromList(bcPtr.asTypedList(len));
      } finally {
        _freeBytes!(bcPtr, len);
      }
    } finally {
      malloc.free(prePtr);
      malloc.free(outLenPtr);
    }
  }

  /// Solves `n` and `sig` challenges with compiled bytecode.
  static QuickJsSolveResult? solveBytecode(
    Uint8List bytecode, {
    String? n,
    String? sig,
  }) {
    if (!isAvailable || _solveBytecode == null || _freeString == null) return null;
    if (bytecode.isEmpty) return null;

    final nPtr = (n != null && n.isNotEmpty) ? n.toNativeUtf8() : nullptr;
    final sigPtr = (sig != null && sig.isNotEmpty) ? sig.toNativeUtf8() : nullptr;
    final bcNative = malloc<Uint8>(bytecode.length);
    bcNative.asTypedList(bytecode.length).setAll(0, bytecode);

    try {
      final resPtr = _solveBytecode!(
        bcNative,
        bytecode.length,
        nPtr.address != 0 ? nPtr : nullptr,
        sigPtr.address != 0 ? sigPtr : nullptr,
      );
      if (resPtr.address == 0) return null;
      try {
        final jsonStr = resPtr.toDartString();
        final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
        return QuickJsSolveResult(
          n: decoded['n']?.toString(),
          sig: decoded['sig']?.toString(),
        );
      } catch (_) {
        return null;
      } finally {
        _freeString!(resPtr);
      }
    } finally {
      malloc.free(bcNative);
      if (nPtr.address != 0) malloc.free(nPtr);
      if (sigPtr.address != 0) malloc.free(sigPtr);
    }
  }

  /// Solves `n` and `sig` challenges with preprocessed JS.
  static QuickJsSolveResult? solve(
    String preprocessedJs, {
    String? n,
    String? sig,
  }) {
    if (!isAvailable || _solve == null || _freeString == null) return null;

    final prePtr = preprocessedJs.toNativeUtf8();
    final nPtr = (n != null && n.isNotEmpty) ? n.toNativeUtf8() : nullptr;
    final sigPtr = (sig != null && sig.isNotEmpty) ? sig.toNativeUtf8() : nullptr;

    try {
      final resPtr = _solve!(
        prePtr,
        nPtr.address != 0 ? nPtr : nullptr,
        sigPtr.address != 0 ? sigPtr : nullptr,
      );
      if (resPtr.address == 0) return null;
      try {
        final jsonStr = resPtr.toDartString();
        final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
        return QuickJsSolveResult(
          n: decoded['n']?.toString(),
          sig: decoded['sig']?.toString(),
        );
      } catch (_) {
        return null;
      } finally {
        _freeString!(resPtr);
      }
    } finally {
      malloc.free(prePtr);
      if (nPtr.address != 0) malloc.free(nPtr);
      if (sigPtr.address != 0) malloc.free(sigPtr);
    }
  }
}

/// Dedicated isolate worker for player preparation and background solving.
class QuickJsCipherIsolate {
  final Dio _dio;
  final String _cacheDir;
  QuickJsPlayer? _activePlayer;
  DateTime? _playerLoadedAt;
  Completer<QuickJsPlayer?>? _preparing;

  QuickJsCipherIsolate(this._dio, {String? cacheDirectory})
      : _cacheDir = cacheDirectory ??
            p.join(Directory.systemTemp.path, 'lastwave_ejs');

  QuickJsPlayer? get activePlayer => _activePlayer;

  /// Returns current preprocessed player, preparing or loading from disk cache.
  Future<QuickJsPlayer?> ensurePlayer() async {
    if (_activePlayer != null && _playerLoadedAt != null) {
      if (DateTime.now().difference(_playerLoadedAt!) < const Duration(hours: 1)) {
        return _activePlayer;
      }
    }
    if (_preparing != null) {
      return _preparing!.future;
    }

    final completer = Completer<QuickJsPlayer?>();
    _preparing = completer;

    try {
      final player = await _loadOrPreparePlayer();
      _activePlayer = player;
      _playerLoadedAt = DateTime.now();
      completer.complete(player);
      return player;
    } catch (e) {
      debugPrint('QuickJsCipherIsolate ensurePlayer error: $e');
      completer.complete(null);
      return null;
    } finally {
      _preparing = null;
    }
  }

  Future<QuickJsPlayer?> _loadOrPreparePlayer() async {
    if (!QuickJsCipher.isAvailable) return null;

    final dir = Directory(_cacheDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    // 1. Get current player version from iframe_api
    final iframeUrl = 'https://www.youtube.com/iframe_api';
    final iframeRes = await _dio.get<String>(
      iframeUrl,
      options: Options(responseType: ResponseType.plain),
    );
    final iframe = iframeRes.data ?? '';
    final id = _extractPlayerId(iframe);
    if (id == null || id.isEmpty) return null;

    final qbcFile = File(p.join(_cacheDir, '$id.qbc'));
    final stsFile = File(p.join(_cacheDir, '$id.sts'));

    // Fast path: load from disk cache
    if (qbcFile.existsSync() && stsFile.existsSync()) {
      try {
        final sts = int.tryParse(await stsFile.readAsString().then((s) => s.trim())) ?? 0;
        final bc = await qbcFile.readAsBytes();
        if (sts > 0 && bc.isNotEmpty) {
          return QuickJsPlayer(
            id: id,
            sts: sts,
            bytecode: bc,
          );
        }
      } catch (_) {}
    }

    // Cold path: fetch base.js and preprocess in background isolate
    final baseJsUrl =
        'https://www.youtube.com/s/player/$id/player_ias.vflset/en_US/base.js';
    final baseRes = await _dio.get<String>(
      baseJsUrl,
      options: Options(responseType: ResponseType.plain),
    );
    final baseJs = baseRes.data ?? '';
    if (baseJs.isEmpty) return null;

    final sts = _extractSignatureTimestamp(baseJs);
    if (sts == null || sts == 0) return null;

    // Run heavy QuickJS preprocessing inside an Isolate
    final (preprocessed, bytecode) = await Isolate.run(() {
      final pre = QuickJsCipher.preprocess(baseJs);
      if (pre == null) return ('', Uint8List(0));
      final bc = QuickJsCipher.compile(pre);
      return (pre, bc ?? Uint8List(0));
    });

    if (bytecode.isEmpty) return null;

    // Prune old player caches
    try {
      for (final f in dir.listSync()) {
        if (f is File && !f.path.contains(id)) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}

    // Save to disk cache
    try {
      await qbcFile.writeAsBytes(bytecode);
      await stsFile.writeAsString(sts.toString());
    } catch (_) {}

    return QuickJsPlayer(
      id: id,
      sts: sts,
      bytecode: bytecode,
      preprocessedJs: preprocessed,
    );
  }

  /// Deciphers a raw URL or signatureCipher parameter.
  Future<String?> decipherUrl(
    String urlOrCipher, {
    QuickJsPlayer? playerOverride,
  }) async {
    final player = playerOverride ?? await ensurePlayer();
    if (player == null || player.bytecode.isEmpty) return null;

    try {
      String url;
      String? sParam;
      String? spParam;

      if (urlOrCipher.startsWith('http://') || urlOrCipher.startsWith('https://')) {
        url = urlOrCipher;
      } else {
        final params = Uri.splitQueryString(urlOrCipher);
        url = params['url'] ?? '';
        sParam = params['s'];
        spParam = params['sp'] ?? 'signature';
      }

      if (url.isEmpty) return null;

      final uri = Uri.tryParse(url);
      if (uri == null) return null;

      final nParam = uri.queryParameters['n'];

      // If neither n nor s needs deciphering, return url
      if ((nParam == null || nParam.isEmpty) && (sParam == null || sParam.isEmpty)) {
        return url;
      }

      // Solve in QuickJS with compiled bytecode (sub-10ms)
      final solved = QuickJsCipher.solveBytecode(
        player.bytecode,
        n: nParam,
        sig: sParam,
      );

      if (solved == null) return null;

      var finalUrl = url;

      if (sParam != null && solved.sig != null) {
        final sp = (spParam != null && spParam.isNotEmpty) ? spParam : 'signature';
        finalUrl = _appendParam(finalUrl, sp, solved.sig!);
      }

      if (nParam != null && solved.n != null) {
        finalUrl = _replaceParam(finalUrl, 'n', solved.n!);
      }

      return finalUrl;
    } catch (e) {
      debugPrint('QuickJsCipher decipherUrl error: $e');
      return null;
    }
  }

  static String _appendParam(String url, String name, String value) {
    final fragIdx = url.indexOf('#');
    final base = fragIdx >= 0 ? url.substring(0, fragIdx) : url;
    final fragment = fragIdx >= 0 ? url.substring(fragIdx) : '';
    final sep = base.endsWith('?') || base.endsWith('&')
        ? ''
        : (base.contains('?') ? '&' : '?');
    return '$base$sep${Uri.encodeQueryComponent(name)}=${Uri.encodeQueryComponent(value)}$fragment';
  }

  static String _replaceParam(String url, String name, String value) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final params = Map<String, String>.from(uri.queryParameters);
    params[name] = value;
    return uri.replace(queryParameters: params).toString();
  }

  static String? _extractPlayerId(String iframe) {
    final match = RegExp(r'player[\\/]+([a-fA-F0-9]{8})[\\/]+').firstMatch(iframe);
    return match?.group(1);
  }

  static int? _extractSignatureTimestamp(String baseJs) {
    final match = RegExp(r'(?:signatureTimestamp|sts)\s*[:=]\s*(\d+)').firstMatch(baseJs);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '');
    }
    return null;
  }
}
