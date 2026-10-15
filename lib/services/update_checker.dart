import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Info about a newer release, when one exists.
class UpdateInfo {
  final String remoteVersion;
  final String currentVersion;
  final String url;

  const UpdateInfo({
    required this.remoteVersion,
    required this.currentVersion,
    required this.url,
  });
}

/// Checks whether a newer Campus Connect is out.
///
/// Reads `version.json` from the repo's main branch (bumped with every
/// release) and compares it with this install's version + build
/// number. Returns null when up to date, offline, or anything fails —
/// the check is best-effort and never blocks the app.
Future<UpdateInfo?> checkForUpdate() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final res = await http
        .get(Uri.parse(
            'https://raw.githubusercontent.com/SUJITHCHALLA12/Campus-Connect/main/version.json'))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final remoteVersion = (json['version'] as String?) ?? '';
    final remoteBuild = (json['build'] as num?)?.toInt() ?? 0;
    if (remoteVersion.isEmpty) return null;
    final localBuild = int.tryParse(info.buildNumber) ?? 0;
    if (!_isNewer(remoteVersion, remoteBuild, info.version, localBuild)) {
      return null;
    }
    return UpdateInfo(
      remoteVersion: remoteVersion,
      currentVersion: info.version,
      url:
          'https://github.com/SUJITHCHALLA12/Campus-Connect/releases/tag/latest',
    );
  } catch (_) {
    return null;
  }
}

/// True when (remoteVersion, remoteBuild) is newer than
/// (localVersion, localBuild). Version compares semver-style
/// (major.minor.patch); build number breaks a tie.
bool _isNewer(
    String remote, int remoteBuild, String local, int localBuild) {
  List<int> parse(String v) =>
      v.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final r = parse(remote);
  final l = parse(local);
  for (var i = 0; i < 3; i++) {
    final rv = i < r.length ? r[i] : 0;
    final lv = i < l.length ? l[i] : 0;
    if (rv != lv) return rv > lv;
  }
  return remoteBuild > localBuild;
}
