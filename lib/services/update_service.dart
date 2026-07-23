import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Checks GitHub Releases for a newer version and returns the metadata
/// so the UI can offer an in-app "Update available" banner. Sideloaded
/// APKs don't get Play Store auto-update — this is our replacement.
class UpdateService {
  static const _api =
      'https://api.github.com/repos/moinrefaii-a11y/Mewsify/releases/latest';

  Future<UpdateInfo?> check() async {
    try {
      final res = await http
          .get(Uri.parse(_api), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = json.decode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String?)?.replaceFirst('v', '') ?? '';
      if (tag.isEmpty) return null;

      final info = await PackageInfo.fromPlatform();
      final current = info.version;
      if (!_isNewer(tag, current)) return null;

      // Find the APK asset.
      String? apkUrl;
      final assets = data['assets'] as List?;
      if (assets != null) {
        for (final a in assets) {
          final name = a['name']?.toString() ?? '';
          if (name.toLowerCase().endsWith('.apk')) {
            apkUrl = a['browser_download_url']?.toString();
            break;
          }
        }
      }

      return UpdateInfo(
        version: tag,
        currentVersion: current,
        notes: (data['body'] as String?) ?? '',
        pageUrl: (data['html_url'] as String?) ??
            'https://github.com/moinrefaii-a11y/Mewsify/releases/latest',
        apkUrl: apkUrl,
      );
    } catch (e) {
      debugPrint('[Update] check failed: $e');
      return null;
    }
  }

  /// Semantic-version-lite comparison. Handles "0.2.1" vs "0.2.0" and
  /// falls through gracefully for anything unusual.
  bool _isNewer(String latest, String current) {
    final l = _parts(latest);
    final c = _parts(current);
    for (var i = 0; i < 3; i++) {
      final a = i < l.length ? l[i] : 0;
      final b = i < c.length ? c[i] : 0;
      if (a > b) return true;
      if (a < b) return false;
    }
    return false;
  }

  List<int> _parts(String v) => v
      .split(RegExp(r'[.+\-]'))
      .map(int.tryParse)
      .whereType<int>()
      .toList();
}

class UpdateInfo {
  final String version;
  final String currentVersion;
  final String notes;
  final String pageUrl;
  final String? apkUrl;
  const UpdateInfo({
    required this.version,
    required this.currentVersion,
    required this.notes,
    required this.pageUrl,
    this.apkUrl,
  });
}
