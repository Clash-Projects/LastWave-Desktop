import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/dio_factory.dart';

class Contributor {
  final String login;
  final String name;
  final String avatarUrl;
  final String profileUrl;
  final String role;
  final int contributions;

  const Contributor({
    required this.login,
    this.name = '',
    required this.avatarUrl,
    required this.profileUrl,
    this.role = 'Contributor',
    this.contributions = 0,
  });

  String get displayName => name.isNotEmpty ? name : login;
}

const List<Contributor> bundledContributors = [
  Contributor(
    login: 'ajisth69',
    name: 'Ajisth Singh',
    avatarUrl: 'https://avatars.githubusercontent.com/ajisth69',
    profileUrl: 'https://github.com/ajisth69',
    role: 'Founder & Lead Maintainer',
    contributions: 292,
  ),
  Contributor(
    login: 'MrinmoyHaloi',
    name: 'Mrinmoy Haloi',
    avatarUrl: 'https://avatars.githubusercontent.com/MrinmoyHaloi',
    profileUrl: 'https://github.com/MrinmoyHaloi',
    role: 'Core Developer (Desktop)',
    contributions: 258,
  ),
  Contributor(
    login: 'duxtami',
    name: 'Duxtami',
    avatarUrl: 'https://avatars.githubusercontent.com/duxtami',
    profileUrl: 'https://github.com/duxtami',
    role: 'Core Developer',
    contributions: 161,
  ),
  Contributor(
    login: 'NONDEADER',
    name: 'Ayush',
    avatarUrl: 'https://avatars.githubusercontent.com/NONDEADER',
    profileUrl: 'https://github.com/NONDEADER',
    role: 'Contributor',
    contributions: 23,
  ),
  Contributor(
    login: 'SYR3X',
    name: 'Kehan Liyanage',
    avatarUrl: 'https://avatars.githubusercontent.com/SYR3X',
    profileUrl: 'https://github.com/SYR3X',
    role: 'Developer',
    contributions: 14,
  ),
  Contributor(
    login: 'Yadnesht909',
    name: 'Yadnesh Teli',
    avatarUrl: 'https://avatars.githubusercontent.com/Yadnesht909',
    profileUrl: 'https://github.com/Yadnesht909',
    role: 'Contributor',
    contributions: 5,
  ),
  Contributor(
    login: 'UmangNamdeo',
    name: 'Umang Namdeo',
    avatarUrl: 'https://avatars.githubusercontent.com/UmangNamdeo',
    profileUrl: 'https://github.com/UmangNamdeo',
    role: 'Contributor',
    contributions: 5,
  ),
  Contributor(
    login: 'Sahank29',
    name: 'Sahan C Poojari',
    avatarUrl: 'https://avatars.githubusercontent.com/Sahank29',
    profileUrl: 'https://github.com/Sahank29',
    role: 'Contributor',
    contributions: 5,
  ),
  Contributor(
    login: 'Abhinav-Abster',
    name: 'Abhinav Ricky',
    avatarUrl: 'https://avatars.githubusercontent.com/Abhinav-Abster',
    profileUrl: 'https://github.com/Abhinav-Abster',
    role: 'Contributor',
    contributions: 4,
  ),
  Contributor(
    login: 'vaibhxvvy',
    name: 'Vaibhav Surthi',
    avatarUrl: 'https://avatars.githubusercontent.com/vaibhxvvy',
    profileUrl: 'https://github.com/vaibhxvvy',
    role: 'Contributor',
    contributions: 3,
  ),
  Contributor(
    login: 'xppenTC',
    name: 'xppenTC',
    avatarUrl: 'https://avatars.githubusercontent.com/xppenTC',
    profileUrl: 'https://github.com/xppenTC',
    role: 'Contributor',
    contributions: 2,
  ),
  Contributor(
    login: 'kanishk-upadhyay',
    name: 'Kanishk Upadhyay',
    avatarUrl: 'https://avatars.githubusercontent.com/kanishk-upadhyay',
    profileUrl: 'https://github.com/kanishk-upadhyay',
    role: 'Contributor',
    contributions: 2,
  ),
  Contributor(
    login: 'JJRPF',
    name: 'Justin Pfister',
    avatarUrl: 'https://avatars.githubusercontent.com/JJRPF',
    profileUrl: 'https://github.com/JJRPF',
    role: 'Contributor',
    contributions: 2,
  ),
  Contributor(
    login: 'AndyDL24',
    name: 'Andrea',
    avatarUrl: 'https://avatars.githubusercontent.com/AndyDL24',
    profileUrl: 'https://github.com/AndyDL24',
    role: 'Contributor',
    contributions: 2,
  ),
];

final contributorsProvider =
    FutureProvider.autoDispose<List<Contributor>>((ref) async {
  final dio = DioFactory.create();
  try {
    final response = await dio.get<List<dynamic>>(
      'https://api.github.com/repos/Clash-Projects/LastWave-Desktop/contributors',
      options: Options(
        headers: {
          'Accept': 'application/vnd.github.v3+json',
        },
        receiveTimeout: const Duration(seconds: 4),
        sendTimeout: const Duration(seconds: 4),
      ),
    );

    final rawList = response.data;
    if (rawList == null || rawList.isEmpty) {
      return bundledContributors;
    }

    // Merge GitHub API response with bundled metadata (roles, names)
    final Map<String, Contributor> merged = {
      for (final c in bundledContributors) c.login.toLowerCase(): c,
    };

    for (final item in rawList) {
      if (item is Map<String, dynamic>) {
        final login = item['login'] as String? ?? '';
        if (login.isEmpty ||
            login.endsWith('[bot]') ||
            login.toLowerCase() == 'claude') {
          continue;
        }
        final key = login.toLowerCase();
        final avatarUrl = item['avatar_url'] as String? ??
            'https://avatars.githubusercontent.com/$login';
        final htmlUrl = item['html_url'] as String? ??
            'https://github.com/$login';
        final contributions = item['contributions'] as int? ?? 1;

        if (merged.containsKey(key)) {
          final existing = merged[key]!;
          merged[key] = Contributor(
            login: existing.login,
            name: existing.name,
            avatarUrl: existing.avatarUrl.isNotEmpty ? existing.avatarUrl : avatarUrl,
            profileUrl: existing.profileUrl.isNotEmpty ? existing.profileUrl : htmlUrl,
            role: existing.role,
            contributions: contributions > existing.contributions ? contributions : existing.contributions,
          );
        } else {
          merged[key] = Contributor(
            login: login,
            avatarUrl: avatarUrl,
            profileUrl: htmlUrl,
            role: 'Contributor',
            contributions: contributions,
          );
        }
      }
    }

    const pinnedLogins = ['ajisth69', 'mrinmoyhaloi', 'duxtami', 'nondeader'];
    final result = merged.values.toList();
    result.sort((a, b) {
      final aKey = a.login.toLowerCase();
      final bKey = b.login.toLowerCase();
      final aPinned = pinnedLogins.indexOf(aKey);
      final bPinned = pinnedLogins.indexOf(bKey);
      if (aPinned != -1 && bPinned != -1) return aPinned.compareTo(bPinned);
      if (aPinned != -1) return -1;
      if (bPinned != -1) return 1;
      return b.contributions.compareTo(a.contributions);
    });

    return result;
  } catch (_) {
    // Return bundled list if offline or rate-limited
    return bundledContributors;
  }
});
