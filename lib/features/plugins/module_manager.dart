import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manifest fields Android `ModuleManager` actually reads from a `.lwp`.
class ProviderManifest {
  final String id;
  final String name;
  final String version;
  final int versionCode;
  final String description;
  final String author;
  final String entryPoint;
  final bool encrypted;
  final String alg;
  final String format;
  final String keyId;
  final List<String> files;
  final List<String> capabilities;

  const ProviderManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.versionCode,
    required this.description,
    required this.author,
    required this.entryPoint,
    required this.encrypted,
    required this.alg,
    required this.format,
    required this.keyId,
    required this.files,
    required this.capabilities,
  });

  factory ProviderManifest.parse(Map<String, dynamic> json) {
    final enc = json['enc'];
    final encMap = enc is Map ? enc : const {};
    return ProviderManifest(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      versionCode: json['versionCode'] is num
          ? (json['versionCode'] as num).toInt()
          : int.tryParse('${json['versionCode'] ?? 0}') ?? 0,
      description: json['description']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      entryPoint: (json['entryPoint']?.toString() ?? '').isEmpty
          ? 'config.json'
          : json['entryPoint'].toString(),
      encrypted: json['encrypted'] == true,
      alg: encMap['alg']?.toString() ?? '',
      format: encMap['format']?.toString() ?? '',
      keyId: encMap['keyId']?.toString() ?? '',
      files: encMap['files'] is List
          ? [for (final f in encMap['files'] as List) f.toString()]
          : const [],
      capabilities: json['capabilities'] is List
          ? [for (final c in json['capabilities'] as List) c.toString()]
          : const [],
    );
  }
}

class InstalledModule {
  final ProviderManifest manifest;
  final bool enabled;
  final int installedAt;
  final String path;

  const InstalledModule({
    required this.manifest,
    required this.enabled,
    required this.installedAt,
    required this.path,
  });
}

class ModuleInstallResult {
  final InstalledModule? module;
  final String error;
  const ModuleInstallResult.ok(this.module) : error = '';
  const ModuleInstallResult.rejected(this.error) : module = null;
  bool get ok => module != null;
}

/// Installs local `.lwp` packages under app support.
///
/// Structural checks match the Android loader (zip, manifest.json,
/// id, entryPoint `config.json`, LWP2 encryption fields, config.json
/// present). This build does not carry the Android module key, so the
/// encrypted config is not decrypted and addon URL playback is unchanged.
class ModuleManager {
  Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'provider_modules'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _registry() async =>
      File(p.join((await _root()).path, 'registry.json'));

  Future<List<InstalledModule>> list() async {
    final file = await _registry();
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      final modules = decoded is Map ? decoded['modules'] : null;
      if (modules is! List) return const [];
      final root = await _root();
      final out = <InstalledModule>[];
      for (final item in modules) {
        if (item is! Map) continue;
        final manifestRaw = item['manifest'];
        if (manifestRaw is! Map) continue;
        final manifest = ProviderManifest.parse(
          manifestRaw.map((k, v) => MapEntry(k.toString(), v)),
        );
        if (manifest.id.isEmpty) continue;
        final path = p.join(root.path, _safeId(manifest.id), 'module.lwp');
        out.add(InstalledModule(
          manifest: manifest,
          enabled: item['enabled'] == true,
          installedAt: item['installedAt'] is num
              ? (item['installedAt'] as num).toInt()
              : 0,
          path: path,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<ModuleInstallResult> installFile(String sourcePath) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      return const ModuleInstallResult.rejected('Cannot read selected file');
    }
    final length = await source.length();
    if (length > 12 * 1024 * 1024) {
      return const ModuleInstallResult.rejected('Refused: package too large');
    }
    final bytes = await source.readAsBytes();
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return const ModuleInstallResult.rejected(
        'Not a valid module: manifest.json missing or broken',
      );
    }
    final manifestFile = _entry(archive, 'manifest.json');
    if (manifestFile == null) {
      return const ModuleInstallResult.rejected(
        'Not a valid module: manifest.json missing or broken',
      );
    }
    Map<String, dynamic> json;
    try {
      final text = utf8.decode(manifestFile.content as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return const ModuleInstallResult.rejected(
          'Not a valid module: manifest.json missing or broken',
        );
      }
      json = decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return const ModuleInstallResult.rejected(
        'Not a valid module: manifest.json missing or broken',
      );
    }
    final manifest = ProviderManifest.parse(json);
    if (manifest.id.isEmpty || manifest.entryPoint.isEmpty) {
      return const ModuleInstallResult.rejected(
        'Module manifest missing id/entryPoint',
      );
    }
    if (manifest.entryPoint != 'config.json') {
      return const ModuleInstallResult.rejected(
        'Refused: legacy JS addon, need config.json',
      );
    }
    if (!manifest.encrypted || manifest.keyId.isEmpty) {
      return const ModuleInstallResult.rejected(
        'Refused: config is not encrypted',
      );
    }
    if (manifest.alg != 'AES-256-GCM' || manifest.format != 'LWP2') {
      return const ModuleInstallResult.rejected('Refused: need LWP2 config');
    }
    if (!manifest.files.contains('config.json')) {
      return const ModuleInstallResult.rejected(
        'Refused: config.json not in enc.files',
      );
    }
    if (_entry(archive, 'config.json') == null) {
      return const ModuleInstallResult.rejected(
        'config.json missing in package',
      );
    }
    final root = await _root();
    final dir = Directory(p.join(root.path, _safeId(manifest.id)));
    await dir.create(recursive: true);
    await Directory(p.join(dir.path, 'store')).create(recursive: true);
    final dest = File(p.join(dir.path, 'module.lwp'));
    await dest.writeAsBytes(bytes, flush: true);
    final existing = await list();
    final kept = existing.where((m) => m.manifest.id != manifest.id);
    final installed = InstalledModule(
      manifest: manifest,
      enabled: true,
      installedAt: DateTime.now().millisecondsSinceEpoch,
      path: dest.path,
    );
    await _write([...kept, installed]);
    return ModuleInstallResult.ok(installed);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final modules = await list();
    await _write([
      for (final module in modules)
        module.manifest.id == id
            ? InstalledModule(
                manifest: module.manifest,
                enabled: enabled,
                installedAt: module.installedAt,
                path: module.path,
              )
            : module,
    ]);
  }

  Future<void> remove(String id) async {
    final root = await _root();
    final dir = Directory(p.join(root.path, _safeId(id)));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    final modules = await list();
    await _write(modules.where((m) => m.manifest.id != id).toList());
  }

  ArchiveFile? _entry(Archive archive, String name) {
    for (final file in archive.files) {
      if (file.isFile && (file.name == name || file.name == name.replaceAll('/', '\\'))) {
        return file;
      }
    }
    return null;
  }

  Future<void> _write(List<InstalledModule> modules) async {
    final file = await _registry();
    final payload = {
      'modules': [
        for (final module in modules)
          {
            'enabled': module.enabled,
            'installedAt': module.installedAt,
            'manifest': {
              'id': module.manifest.id,
              'name': module.manifest.name,
              'version': module.manifest.version,
              'versionCode': module.manifest.versionCode,
              'description': module.manifest.description,
              'author': module.manifest.author,
              'entryPoint': module.manifest.entryPoint,
              'encrypted': module.manifest.encrypted,
              'capabilities': module.manifest.capabilities,
              'enc': {
                'alg': module.manifest.alg,
                'format': module.manifest.format,
                'keyId': module.manifest.keyId,
                'files': module.manifest.files,
              },
            },
          },
      ],
    };
    await file.writeAsString(jsonEncode(payload));
  }

  String _safeId(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (cleaned.isEmpty) return 'module';
    return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
  }
}

final moduleManagerProvider = Provider<ModuleManager>((ref) => ModuleManager());

/// Bumped when modules are installed or removed so Settings rebuilds.
final moduleListProvider = FutureProvider<List<InstalledModule>>((ref) {
  return ref.watch(moduleManagerProvider).list();
});
