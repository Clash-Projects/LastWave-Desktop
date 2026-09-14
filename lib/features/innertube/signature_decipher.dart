import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

/// YouTube player signature decipher (pure Dart).
///
/// Ports what LastWave-native delegates to NewPipe's
/// `YoutubeJavaScriptPlayerManager` + `YoutubeSignatureUtils` +
/// `YoutubeThrottlingParameterUtils`:
/// - function discovery uses NewPipe's CURRENT patterns (call-site
///   `decodeURIComponent` patterns first, split/join shape last)
/// - signature timestamp comes from base.js
///   (`signatureTimestamp[=:](\d+)`), not the watch page
/// - throttling (`n`) discovery uses the `"nn"`/`.get("n")`
///   call-site patterns
///
/// NewPipe EXECUTES the extracted code with Rhino; here the ops are
/// applied by a small static interpreter (reverse/splice/slice/
/// swap/shift/unshift/pop/push) because Dart has no JS engine.
/// Anything unresolvable fails that format loudly so callers fall
/// through to the next format or client — final validity is always
/// decided by stream probing, exactly like Android.
enum DecipherOpType {
  reverse,
  splice,
  slice,
  swap,
  shift,
  unshift,
  pop,
  push,
}

class DecipherOp {
  final DecipherOpType type;
  final List<int> args;
  const DecipherOp(this.type, [this.args = const []]);
}

class PlayerScript {
  final int? sts;
  final String jsUrl;
  final String sigName;
  final List<DecipherOp> sigOps;
  final Map<String, int> sigEnv;
  final String sigArrayVar;
  final String? nName;
  final List<DecipherOp>? nOps;
  final Map<String, int> nEnv;
  final String nArrayVar;
  const PlayerScript({
    required this.sts,
    required this.jsUrl,
    required this.sigName,
    required this.sigOps,
    required this.sigEnv,
    required this.sigArrayVar,
    this.nName,
    this.nOps,
    this.nEnv = const {},
    this.nArrayVar = '',
  });
}

class SignatureDecipher {
  final Dio _dio;
  final Map<String, PlayerScript> _byJsUrl = {};
  final Map<String, Map<String, String>> _nCache = {};

  SignatureDecipher(this._dio);

  static const _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) '
      'Gecko/20100101 Firefox/140.0';

  /// Watch-page player info: base.js URL, mirroring NewPipe's
  /// `YoutubeJavaScriptExtractor` (embed page, `player_ias`
  /// variant — the structure NewPipe's patterns match).
  Future<({int? sts, String? jsUrl})> playerInfo(
      String videoId) async {
    String? jsUrl;
    for (final page in [
      'https://www.youtube.com/embed/$videoId',
      'https://www.youtube.com/watch?v=$videoId',
    ]) {
      try {
        final res = await _dio.get<String>(
          page,
          queryParameters: {'hl': 'en'},
          options: Options(
            headers: {
              'User-Agent': _webUa,
              'Accept-Language': 'en-US,en;q=0.9',
            },
            responseType: ResponseType.plain,
          ),
        ).timeout(const Duration(seconds: 15));
        final html = res.data ?? '';
        jsUrl = RegExp(
                r'"jsUrl":"(/s/player/[A-Za-z0-9]+/player_ias\.vflset/[A-Za-z_-]+/base\.js)"')
            .firstMatch(html)
            ?.group(1);
        jsUrl ??= RegExp(r'"jsUrl"\s*:\s*"([^"]+)"')
            .firstMatch(html)
            ?.group(1);
        if (jsUrl != null) break;
      } catch (_) {}
    }
    if (jsUrl != null) {
      jsUrl = jsUrl.replaceAll(r'\/', '/');
      if (jsUrl.startsWith('/')) {
        jsUrl = 'https://www.youtube.com$jsUrl';
      }
      return (sts: null, jsUrl: jsUrl);
    }
    return (sts: null, jsUrl: null);
  }

  Future<int?> getSignatureTimestamp(String videoId) async {
    try {
      final script = await scriptFor(videoId)
          .timeout(const Duration(seconds: 25));
      return script?.sts;
    } catch (_) {
      return null;
    }
  }

  Future<PlayerScript?> scriptFor(String videoId) async {
    final info = await playerInfo(videoId);
    final jsUrl = info.jsUrl;
    if (jsUrl == null || jsUrl.isEmpty) return null;
    final cached = _byJsUrl[jsUrl];
    if (cached != null) return cached;
    try {
      final res = await _dio.get<String>(
        jsUrl,
        options: Options(
          headers: {'User-Agent': _webUa},
          responseType: ResponseType.plain,
        ),
      ).timeout(const Duration(seconds: 20));
      final js = res.data ?? '';
      if (js.isEmpty) return null;
      final script = _parse(jsUrl, js);
      if (script == null) return null;
      if (_byJsUrl.length > 8) {
        _byJsUrl.clear();
        _nCache.clear();
      }
      _byJsUrl[jsUrl] = script;
      return script;
    } catch (_) {
      return null;
    }
  }

  /// Decipher a `signatureCipher` (or `cipher`) query string into a
  /// playable URL. Returns null when undecipherable.
  String? decipherUrl(
    String signatureCipher,
    PlayerScript script,
  ) {
    try {
      final params = Uri.splitQueryString(
        signatureCipher,
        encoding: utf8,
      );
      var url = params['url'];
      if (url == null || url.isEmpty) return null;
      final encrypted = params['s'];
      if (encrypted != null && encrypted.isNotEmpty) {
        final signature =
            _apply(script.sigOps, script.sigEnv, encrypted);
        final sp = (params['sp']?.isNotEmpty ?? false)
            ? params['sp']!
            : 'signature';
        url = _appendParam(url, sp, signature);
      }
      final uri = Uri.tryParse(url);
      final n = uri?.queryParameters['n'];
      final nOps = script.nOps;
      if (n != null && n.isNotEmpty && nOps != null) {
        final cached = _nCache[script.jsUrl]?[n];
        if (cached != null) {
          url = _replaceParam(url, 'n', cached);
        } else {
          final fixed = _apply(nOps, script.nEnv, n);
          if (fixed.isEmpty) return url;
          _nCache
              .putIfAbsent(script.jsUrl, () => {})[n] = fixed;
          url = _replaceParam(url, 'n', fixed);
        }
      }
      return url;
    } catch (_) {
      return null;
    }
  }

  /// Test hook: parse [js] without network.
  @visibleForTesting
  PlayerScript? parseForTest(String jsUrl, String js) =>
      _parse(jsUrl, js);

  // -- discovery (NewPipe's patterns, in order) ----------------------------------

  static final List<RegExp> _sigNamePatterns = [
    RegExp(
        r'\b(?:[a-zA-Z0-9_$]+)&&\((?:[a-zA-Z0-9_$]+)=([a-zA-Z0-9_$]{2,})\((\d+),decodeURIComponent\((?:[a-zA-Z0-9_$]+)\)\)'),
    RegExp(
        r'\b(?:[a-zA-Z0-9_$]+)&&\((?:[a-zA-Z0-9_$]+)=([a-zA-Z0-9_$]{2,})\(decodeURIComponent\((?:[a-zA-Z0-9_$]+)\)\)'),
    RegExp(r'\bm=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(h\.s\)\)'),
    RegExp(r'\bc&&\(c=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(c\)\)'),
    RegExp(
        r'(?:\b|[^a-zA-Z0-9$])([a-zA-Z0-9$]{2,})\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\)'),
    RegExp(
        r'([\w$]+)\s*=\s*function\((\w+)\)\{\s*\2=\s*\2\.split\(""\)\s*;'),
  ];

  static const _sc = r'[a-zA-Z0-9$_]';
  static const _mc = '[a-zA-Z0-9\$_]+';

  static final List<RegExp> _nNamePatterns = [
    // m85=function( ... return Y[45]
    RegExp('([A-Za-z0-9_\\\$]{2,})=function.*return [A-Z]\\[\\d+\\]',
        dotAll: true),
    // (b="nn"[+a.D],WL(a),c=a.j[b]||null)&&(c=SDa[0](c),...
    RegExp(
        '$_sc="nn"\\[\\+$_mc\\.$_mc\\],$_mc\\($_mc\\),$_mc=$_mc\\.$_mc\\[$_mc\\]\\|\\|null\\)&&\\($_mc=($_mc)\\[(\\d+)\\]'),
    // ...)&&(c=SDa[0](c),...)...||Wma("")
    RegExp(
        '$_sc="nn"\\[\\+$_mc\\.$_mc\\],$_mc\\($_mc\\),$_mc=$_mc\\.$_mc\\[$_mc\\]\\|\\|null\\).+\\|\\|($_mc)\\(\\"\\"\\)'),
    // ,Vb(m),W=m.j[c]||null)&&(W=cvb[0](W),m.set(c,W)
    RegExp(
        ',$_mc\\($_mc\\),$_mc=$_mc\\.$_mc\\[$_mc\\]\\|\\|null\\)&&\\(\\b$_mc=($_mc)\\[(\\d+)\\]\\($_sc\\),$_mc\\.set\\((?:"n+"|$_mc),$_mc\\)'),
    // a.D&&(b="nn"[+a.D],c=a.get(b))&&(c=rDa[0](c),...,rma("")
    RegExp(
        '$_sc="nn"\\[\\+$_mc\\.$_mc\\],$_mc=$_mc\\.get\\($_mc\\)\\).+\\|\\|($_mc)\\(\\"\\"\\)'),
    // a.D&&(b="nn"[+a.D],c=a.get(b))&&(c=rDa[0](c),...
    RegExp(
        '$_sc="nn"\\[\\+$_mc\\.$_mc\\],$_mc=$_mc\\.get\\($_mc\\)\\)&&\\($_mc=($_mc)\\[(\\d+)\\]'),
    // (b=String.fromCharCode(110),c=a.get(b))&&(c=BDa[0](c)
    RegExp(
        '\\($_sc=String\\.fromCharCode\\(110\\),$_sc=$_sc\\.get\\($_sc\\)\\)&&\\($_sc=($_mc)(?:\\[(\\d+)\\])?\\($_sc\\)'),
    // .get("n"))&&(b=Yva[0](b)
    RegExp(
        '\\.get\\("n"\\)\\)&&\\($_sc=($_mc)(?:\\[(\\d+)\\])?\\($_sc\\)'),
  ];

  PlayerScript? _parse(String jsUrl, String js) {
    // STS lives in the player script (NewPipe: signatureTimestamp[=:](\d+)).
    final sts = RegExp(r'signatureTimestamp[=:](\d+)')
        .firstMatch(js)
        ?.group(1)
        .let((s) => int.tryParse(s ?? ''));

    String? sigName;
    String? sigExtra;
    for (final pattern in _sigNamePatterns) {
      final m = pattern.firstMatch(js);
      if (m == null) continue;
      sigName = m.group(1);
      if (m.groupCount > 1) {
        try {
          sigExtra = m.group(2);
        } catch (_) {
          sigExtra = null;
        }
      }
      break;
    }
    if (sigName == null || sigName.isEmpty) return null;

    late final String sigBody;
    late final List<String> sigParams;
    try {
      final found = _extractFunction(js, sigName);
      sigBody = found.body;
      sigParams = found.params;
    } catch (e) {
      return null;
    }
    final _Prepared prepared;
    try {
      prepared = _prepare(js, sigBody, sigParams,
          extraLiteral: sigExtra);
    } catch (_) {
      return null;
    }
    if (prepared.ops.isEmpty) return null;

    String? nName;
    List<DecipherOp>? nOps;
    Map<String, int> nEnv = const {};
    String nArrayVar = '';
    try {
      final nFound = _findNFunc(js);
      if (nFound != null) {
        nName = nFound;
        final nExtracted = _extractFunction(js, nFound);
        final nPrepared =
            _prepare(js, nExtracted.body, nExtracted.params);
        if (nPrepared.ops.isNotEmpty) {
          nOps = nPrepared.ops;
          nEnv = nPrepared.env;
          nArrayVar = nPrepared.arrayVar;
        }
      }
    } catch (_) {
      nOps = null;
    }

    return PlayerScript(
      sts: sts,
      jsUrl: jsUrl,
      sigName: sigName,
      sigOps: prepared.ops,
      sigEnv: prepared.env,
      sigArrayVar: prepared.arrayVar,
      nName: nName,
      nOps: nOps,
      nEnv: nEnv,
      nArrayVar: nArrayVar,
    );
  }

  /// Extract `NAME=function(...)` source with balanced braces
  /// (lexer approach, mirroring NewPipe).
  _FuncCode _extractFunction(String js, String name) {
    final idx = js.indexOf('$name=function');
    if (idx < 0) throw const FormatException('no func');
    final openIdx = js.indexOf('{', idx);
    if (openIdx < 0) throw const FormatException('no body');
    final sig =
        RegExp(RegExp.escape(name) + r'\s*=\s*function\s*\(([^)]*)\)')
            .firstMatch(js.substring(idx, openIdx + 1));
    final params = sig
            ?.group(1)
            ?.split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList() ??
        const [];
    return _FuncCode(
      body: _balanced(js, openIdx),
      params: params,
    );
  }

  /// Strip NewPipe-style early-return guards, bind the array
  /// variable + extra literals, and compile op statements.
  _Prepared _prepare(String js, String body, List<String> params,
      {String? extraLiteral}) {
    final env = <String, int>{};
    late final String arrayVar;
    if (extraLiteral != null &&
        extraLiteral.isNotEmpty &&
        params.length > 1) {
      final extra = int.tryParse(extraLiteral);
      if (extra == null) {
        throw const FormatException('extra not numeric');
      }
      env[params.first] = extra;
      arrayVar = params[1];
    } else if (params.isNotEmpty) {
      arrayVar = params.first;
    } else {
      throw const FormatException('no params');
    }
    // Statements live between `<arr>.split("")` and `return`,
    // located positionally (immune to match offsets).
    final splitIdx = body.indexOf('.split("")');
    if (splitIdx < 0) throw const FormatException('no split');
    var stmts = body.substring(splitIdx + '.split("")'.length);
    final retIdx = stmts.indexOf('return');
    if (retIdx >= 0) stmts = stmts.substring(0, retIdx);
    // Remove `if(typeof XX==="undefined")return <firstArg>;` guards:
    // standalone, the checked value is always defined.
    if (params.isNotEmpty) {
      final first = RegExp.escape(params.first);
      stmts = stmts.replaceAll(
          RegExp(';\\s*if\\s*\\(\\s*typeof\\s+[A-Za-z0-9_\$]+'
              '\\s*===?\\s*(["\'])undefined\\1\\s*\\)\\s*return\\s+'
              '$first\\s*;'),
          ';');
    }
    final ops = <DecipherOp>[];
    for (final raw in stmts.split(';')) {
      final stmt = raw.trim();
      if (stmt.isEmpty ||
          stmt.startsWith('return') ||
          stmt.startsWith('var ') ||
          stmt.startsWith('let ') ||
          stmt.startsWith('const ')) {
        continue;
      }
      final av = RegExp.escape(arrayVar);
      final call = RegExp('^([A-Za-z0-9_\$]+)\\.([A-Za-z0-9_\$]+)'
              '\\(\\s*$av\\s*(?:,\\s*(.+?))?\\)\$')
          .firstMatch(stmt);
      if (call != null) {
        ops.add(_resolveOp(js, call.group(1)!, call.group(2)!,
            call.group(3), env));
        continue;
      }
      if (stmt == '$arrayVar.reverse()') {
        ops.add(const DecipherOp(DecipherOpType.reverse));
        continue;
      }
      throw FormatException('unknown stmt: $stmt');
    }
    if (ops.isEmpty) throw const FormatException('no ops');
    return _Prepared(ops, env, arrayVar);
  }

  String? _findNFunc(String js) {
    for (final pattern in _nNamePatterns) {
      final m = pattern.firstMatch(js);
      if (m == null) continue;
      var name = m.group(1);
      if (name == null || name.isEmpty) continue;
      String? idx;
      try {
        idx = m.groupCount > 1 ? m.group(2) : null;
      } catch (_) {
        idx = null;
      }
      if (idx != null) {
        // `var NAME=[a,b,c];` + index → resolve the real name.
        final arr = RegExp(RegExp.escape(name) +
                r'\s*=\s*\[(.+?)\][;,]')
            .firstMatch(js)
            ?.group(1);
        if (arr == null) continue;
        final names = arr.split(',');
        final at = int.tryParse(idx) ?? -1;
        if (at < 0 || at >= names.length) continue;
        name = names[at].trim();
        if (name.isEmpty) continue;
      }
      return name;
    }
    return null;
  }

  // -- helper objects + op classification --------------------------------------

  DecipherOp _resolveOp(String js, String obj, String method,
      String? argSrc, Map<String, int> outerEnv) {
    final helper = _helperBody(js, obj);
    final member = _memberBody(helper, method);
    final params = _memberParams(helper, method);
    final callArgs =
        argSrc == null || argSrc.trim().isEmpty ? const <String>[] : _splitArgs(argSrc);
    final env = Map<String, int>.of(outerEnv);
    for (var i = 0; i < callArgs.length && i + 1 < params.length; i++) {
      final v = _evalInt(callArgs[i], env, 0);
      if (v != null) env[params[i + 1]] = v;
    }
    return _classify(member, env);
  }

  String _helperBody(String js, String obj) {
    // Helper objects are `var NAME={...};` (2+ char names).
    final m = RegExp('(?:var\\s+)?${RegExp.escape(obj)}\\s*=\\s*\\{')
        .firstMatch(js);
    if (m == null) throw FormatException('no helper $obj');
    final start = js.indexOf('{', m.start);
    return _balanced(js, start);
  }

  String _memberBody(String helper, String method) {
    var m = RegExp(RegExp.escape(method) +
            r'\s*:\s*function\s*\(([^)]*)\)\s*\{')
        .firstMatch(helper);
    if (m != null) {
      return _balanced(
          helper, m.end - 1);
    }
    m = RegExp(
            RegExp.escape(method) + r'\s*\(([^)]*)\)\s*\{')
        .firstMatch(helper);
    if (m != null) {
      return _balanced(
          helper, m.end - 1);
    }
    throw FormatException('no member $method');
  }

  List<String> _memberParams(String helper, String method) {
    final m = RegExp(RegExp.escape(method) +
            r'\s*(?::\s*function)?\s*\(([^)]*)\)\s*\{')
        .firstMatch(helper);
    if (m == null) return const [];
    return m
        .group(1)!
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  DecipherOp _classify(String body, Map<String, int> env) {
    final b = body.replaceAll(RegExp(r'\s+'), '');
    if (b.contains('.reverse(')) return const DecipherOp(DecipherOpType.reverse);
    if (b.contains('.splice(')) {
      final m =
          RegExp(r'\.splice\(([^)]*)\)').firstMatch(b);
      return _spliceOp(
          _splitArgs(m?.group(1) ?? ''), env);
    }
    if (b.contains('.slice(')) {
      final m =
          RegExp(r'\.slice\(([^),]*)').firstMatch(b);
      final n = _evalInt(m?.group(1) ?? '0', env, 0) ?? 0;
      return DecipherOp(DecipherOpType.slice, [n]);
    }
    if (b.contains('.push(')) {
      final m = RegExp(r'\.push\(([^)]*)\)').firstMatch(b);
      final n = _evalInt(m?.group(1) ?? '', env, -1);
      if (n == null || n < 0) {
        throw const FormatException('push arg');
      }
      return DecipherOp(DecipherOpType.push, [n]);
    }
    if (b.contains('.unshift(')) {
      final m =
          RegExp(r'\.unshift\(([^)]*)\)').firstMatch(b);
      final n = _evalInt(m?.group(1) ?? '', env, -1);
      if (n == null || n < 0) {
        throw const FormatException('unshift arg');
      }
      return DecipherOp(DecipherOpType.unshift, [n]);
    }
    if (b.contains('.shift(')) {
      return const DecipherOp(DecipherOpType.shift);
    }
    if (b.contains('.pop(')) {
      return const DecipherOp(DecipherOpType.pop);
    }
    final swap = RegExp(r'\[([^\]]+)%').firstMatch(b);
    if (b.contains('[0]') && swap != null) {
      final n = _evalInt(swap.group(1)!, env, 0) ?? 0;
      return DecipherOp(DecipherOpType.swap, [n]);
    }
    throw const FormatException('unknown op');
  }

  DecipherOp _spliceOp(List<String> args, Map<String, int> env) {
    if (args.length >= 2) {
      final start = _evalInt(args[0], env, 0) ?? 0;
      final count = _evalInt(args[1], env, 0) ?? 0;
      return DecipherOp(DecipherOpType.splice, [start, count]);
    }
    final start =
        args.isNotEmpty ? (_evalInt(args[0], env, 0) ?? 0) : 0;
    return DecipherOp(DecipherOpType.splice, [start]);
  }

  List<String> _splitArgs(String src) {
    final out = <String>[];
    var depth = 0;
    final buf = StringBuffer();
    for (var i = 0; i < src.length; i++) {
      final c = src[i];
      if (c == '(' || c == '[') depth++;
      if (c == ')' || c == ']') depth--;
      if (c == ',' && depth == 0) {
        out.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString().trim());
    return out;
  }

  int? _evalInt(String expr, Map<String, int> env, int len) {
    final e = expr.trim();
    final lit = int.tryParse(e);
    if (lit != null) return lit;
    if (env.containsKey(e)) return env[e];
    final mod =
        RegExp(r'^([A-Za-z0-9_$]+)\s*%\s*[A-Za-z0-9_$.]+\.length$')
            .firstMatch(e);
    if (mod != null) {
      final v = _evalInt(mod.group(1)!, env, len);
      if (v != null && len > 0) return v % len;
      return v;
    }
    return null;
  }

  String _balanced(String src, int openIdx) {
    var depth = 0;
    var inStr = '';
    var escaped = false;
    for (var i = openIdx; i < src.length; i++) {
      final c = src[i];
      if (inStr.isNotEmpty) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == inStr) {
          inStr = '';
        }
        continue;
      }
      if (c == '"' || c == "'" || c == '`') {
        inStr = c;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return src.substring(openIdx + 1, i);
      }
    }
    throw const FormatException('unbalanced');
  }

  // -- application -----------------------------------------------------

  String _apply(List<DecipherOp> ops, Map<String, int> env, String input) {
    if (input.isEmpty) throw const FormatException('empty');
    var chars = input.split('');
    for (final op in ops) {
      switch (op.type) {
        case DecipherOpType.reverse:
          chars = chars.reversed.toList();
        case DecipherOpType.splice:
          final start = op.args[0].clamp(0, chars.length);
          final end = op.args.length > 1
              ? (start + op.args[1]).clamp(0, chars.length)
              : chars.length;
          chars = [...chars.sublist(0, start), ...chars.sublist(end)];
        case DecipherOpType.slice:
          chars = chars.sublist(op.args[0].clamp(0, chars.length));
        case DecipherOpType.swap:
          if (chars.isEmpty) break;
          final n = op.args[0] % chars.length;
          final c = chars[0];
          chars[0] = chars[n];
          chars[n] = c;
        case DecipherOpType.shift:
          if (chars.isNotEmpty) chars = chars.sublist(1);
        case DecipherOpType.unshift:
          chars = [
            String.fromCharCode(op.args[0]),
            ...chars
          ];
        case DecipherOpType.pop:
          if (chars.isNotEmpty) {
            chars = chars.sublist(0, chars.length - 1);
          }
        case DecipherOpType.push:
          chars = [
            ...chars,
            String.fromCharCode(op.args[0])
          ];
      }
    }
    return chars.join();
  }

  String _appendParam(String url, String name, String value) {
    final fragIdx = url.indexOf('#');
    final base = fragIdx >= 0 ? url.substring(0, fragIdx) : url;
    final fragment = fragIdx >= 0 ? url.substring(fragIdx) : '';
    final sep = base.endsWith('?') || base.endsWith('&')
        ? ''
        : (base.contains('?') ? '&' : '?');
    return '$base$sep${Uri.encodeQueryComponent(name)}=${Uri.encodeQueryComponent(value)}$fragment';
  }

  String _replaceParam(String url, String name, String value) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final params = Map<String, String>.from(uri.queryParameters);
    params[name] = value;
    return uri.replace(queryParameters: params).toString();
  }
}

class _FuncCode {
  final String body;
  final List<String> params;
  const _FuncCode({required this.body, required this.params});
}

class _Prepared {
  final List<DecipherOp> ops;
  final Map<String, int> env;
  final String arrayVar;
  const _Prepared(this.ops, this.env, this.arrayVar);
}

extension _Let<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
}
