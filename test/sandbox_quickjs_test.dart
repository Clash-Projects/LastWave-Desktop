import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

typedef PreprocessFunc = Pointer<Utf8> Function(Pointer<Utf8> baseJs);
typedef PreprocessDart = Pointer<Utf8> Function(Pointer<Utf8> baseJs);

typedef SolveFunc = Pointer<Utf8> Function(
  Pointer<Utf8> preprocessed,
  Pointer<Utf8> n,
  Pointer<Utf8> sig,
);
typedef SolveDart = Pointer<Utf8> Function(
  Pointer<Utf8> preprocessed,
  Pointer<Utf8> n,
  Pointer<Utf8> sig,
);

typedef SolveBytecodeFunc = Pointer<Utf8> Function(
  Pointer<Uint8> bcPtr,
  IntPtr bcLen,
  Pointer<Utf8> n,
  Pointer<Utf8> sig,
);
typedef SolveBytecodeDart = Pointer<Utf8> Function(
  Pointer<Uint8> bcPtr,
  int bcLen,
  Pointer<Utf8> n,
  Pointer<Utf8> sig,
);

typedef CompileFunc = Pointer<Uint8> Function(
  Pointer<Utf8> preprocessed,
  Pointer<IntPtr> outLen,
);
typedef CompileDart = Pointer<Uint8> Function(
  Pointer<Utf8> preprocessed,
  Pointer<IntPtr> outLen,
);

typedef FreeStringFunc = Void Function(Pointer<Utf8> ptr);
typedef FreeStringDart = void Function(Pointer<Utf8> ptr);

typedef FreeBytesFunc = Void Function(Pointer<Uint8> ptr, IntPtr len);
typedef FreeBytesDart = void Function(Pointer<Uint8> ptr, int len);

void main() {
  group('QuickJS Cipher Native Sandbox Tests', () {
    late DynamicLibrary lib;
    late PreprocessDart preprocess;
    late SolveDart solve;
    late SolveBytecodeDart solveBytecode;
    late CompileDart compile;
    late FreeStringDart freeString;
    late FreeBytesDart freeBytes;

    setUpAll(() {
      final dllPath = File('quickjs_cipher.dll').existsSync()
          ? 'quickjs_cipher.dll'
          : 'windows/quickjs_cipher.dll';
      lib = DynamicLibrary.open(dllPath);

      preprocess = lib
          .lookup<NativeFunction<PreprocessFunc>>('quickjs_cipher_preprocess')
          .asFunction();
      solve = lib
          .lookup<NativeFunction<SolveFunc>>('quickjs_cipher_solve')
          .asFunction();
      solveBytecode = lib
          .lookup<NativeFunction<SolveBytecodeFunc>>('quickjs_cipher_solve_bytecode')
          .asFunction();
      compile = lib
          .lookup<NativeFunction<CompileFunc>>('quickjs_cipher_compile')
          .asFunction();
      freeString = lib
          .lookup<NativeFunction<FreeStringFunc>>('quickjs_cipher_free_string')
          .asFunction();
      freeBytes = lib
          .lookup<NativeFunction<FreeBytesFunc>>('quickjs_cipher_free_bytes')
          .asFunction();
    });

    test('Preprocess base.js and solve challenges via QuickJS and Bytecode', () async {
      print('Fetching real base.js from YouTube...');
      final dio = Dio();
      final res = await dio.get<String>(
        'https://www.youtube.com/s/player/6b3d0364/player_ias.vflset/en_US/base.js',
      );
      final baseJs = res.data!;
      expect(baseJs.length, greaterThan(1000000));
      print('Fetched base.js: ${baseJs.length} bytes');

      print('Running quickjs_cipher_preprocess...');
      final sw = Stopwatch()..start();
      final baseJsPtr = baseJs.toNativeUtf8();
      final prePtr = preprocess(baseJsPtr);
      malloc.free(baseJsPtr);

      expect(prePtr.address != 0, isTrue);
      final preStr = prePtr.toDartString();
      freeString(prePtr);
      sw.stop();
      print('Preprocessed player length: ${preStr.length} in ${sw.elapsedMilliseconds} ms');
      expect(preStr, contains('_result'));

      print('Compiling to QuickJS bytecode...');
      sw.reset();
      sw.start();
      final preNative = preStr.toNativeUtf8();
      final outLenPtr = malloc<IntPtr>();
      final bcPtr = compile(preNative, outLenPtr);
      final bcLen = outLenPtr.value;
      malloc.free(outLenPtr);
      sw.stop();
      print('Compiled bytecode size: $bcLen bytes in ${sw.elapsedMilliseconds} ms');
      expect(bcLen, greaterThan(1000));

      final testN = '5qZl8A9tM_test1';
      final testSig = 'AABBCCDDEEFFGGHHIIJJKKLLMMNNOOPPQQRRSSTTUUVV';

      print('Solving challenge with preprocessed JS...');
      sw.reset();
      sw.start();
      final nPtr = testN.toNativeUtf8();
      final sigPtr = testSig.toNativeUtf8();
      final resPtr = solve(preNative, nPtr, sigPtr);
      sw.stop();
      expect(resPtr.address != 0, isTrue);
      final jsonStr = resPtr.toDartString();
      freeString(resPtr);
      print('Solved in ${sw.elapsedMilliseconds} ms: $jsonStr');

      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(decoded.containsKey('n'), isTrue);
      expect(decoded['n'], isNotNull);
      print('Deciphered n: ${decoded['n']}');

      print('Solving challenge with compiled bytecode...');
      sw.reset();
      sw.start();
      final resBcPtr = solveBytecode(bcPtr, bcLen, nPtr, sigPtr);
      sw.stop();
      expect(resBcPtr.address != 0, isTrue);
      final jsonBcStr = resBcPtr.toDartString();
      freeString(resBcPtr);
      print('Bytecode solved in ${sw.elapsedMilliseconds} ms: $jsonBcStr');

      final decodedBc = jsonDecode(jsonBcStr) as Map<String, dynamic>;
      expect(decodedBc['n'], equals(decoded['n']));

      malloc.free(nPtr);
      malloc.free(sigPtr);
      malloc.free(preNative);
      freeBytes(bcPtr, bcLen);
    });
  });
}
