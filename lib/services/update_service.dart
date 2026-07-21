import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_version.dart';

/// Manages checking for updates from GitHub releases.
/// Supports "skip this version" so the dialog doesn't re-prompt.
class UpdateService {
  static const _skippedVersionKey = 'skipped_update_version';

  /// Check for a new version. Returns the latest tag if newer, or null if same.
  static Future<String?> fetchLatestTag() async {
    try {
      final response = await http.get(
        Uri.parse(AppVersion.githubReleasesUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['tag_name'] as String?;
      }
    } catch (_) {}
    return null;
  }

  /// Check if [latestTag] is actually newer than our current [versionName].
  static bool isNewer(String latestTag, String currentVersion) {
    // Tags are like v1.1.0, current is like 1.1.0+2021
    final tagVer = latestTag.replaceFirst('v', '').trim();
    final curVer = currentVersion.split('+').first.trim();
    return _compareVersions(tagVer, curVer) > 0;
  }

  /// Simple semver compare: "1.2.0" > "1.1.0"
  static int _compareVersions(String a, String b) {
    final aParts = a.split('.').map(int.tryParse).whereType<int>().toList();
    final bParts = b.split('.').map(int.tryParse).whereType<int>().toList();
    final maxLen = aParts.length > bParts.length ? aParts.length : bParts.length;
    for (int i = 0; i < maxLen; i++) {
      final aVal = i < aParts.length ? aParts[i] : 0;
      final bVal = i < bParts.length ? bParts[i] : 0;
      if (aVal != bVal) return aVal - bVal;
    }
    return 0;
  }

  /// Get the currently skipped version (null if none).
  static Future<String?> getSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_skippedVersionKey);
  }

  /// Skip [tag] so it won't prompt again.
  static Future<void> skipVersion(String tag) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, tag);
  }

  /// Clear any skipped version (re-enables update prompt for that version).
  static Future<void> clearSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_skippedVersionKey);
  }

  /// Silent auto-check — returns update info without showing dialogs.
  /// Returns (latestTag, isNewer, wasSkipped).
  static Future<({
    String? latestTag,
    bool newerExists,
    String? downloadUrl,
  })> silentCheck() async {
    final latestTag = await fetchLatestTag();
    if (latestTag == null || latestTag.isEmpty) {
      return (latestTag: null, newerExists: false, downloadUrl: null);
    }

    final newer = isNewer(latestTag, AppVersion.versionName);
    if (!newer) {
      return (latestTag: latestTag, newerExists: false, downloadUrl: null);
    }

    final skipped = await getSkippedVersion();
    if (skipped == latestTag) {
      return (latestTag: latestTag, newerExists: false, downloadUrl: null);
    }

    final downloadUrl =
        '${AppVersion.downloadBaseUrl}/Apex-Agent-$latestTag.apk';
    return (
      latestTag: latestTag,
      newerExists: true,
      downloadUrl: downloadUrl,
    );
  }

  /// Show the update dialog with Update / Skip / Dismiss buttons.
  static void showUpdateDialog(
    BuildContext context, {
    required String latestTag,
    required String downloadUrl,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded, color: Colors.amber),
            const SizedBox(width: 8),
            const Text('Update Available'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Version $latestTag is available!',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Current version: ${AppVersion.versionName}\n\n'
              'Tap Update to download the latest APK from GitHub.',
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
            },
            child: const Text('Dismiss'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              UpdateService.skipVersion(latestTag);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Version $latestTag will be skipped. '
                      'You can check again in Settings.'),
                ),
              );
            },
            child: const Text('Skip This Version'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(
                Uri.parse(downloadUrl),
                mode: LaunchMode.externalApplication,
              );
            },
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Update Now'),
          ),
        ],
      ),
    );
  }

  /// Full check with dialog — used by manual "Check" button in Settings.
  static Future<void> checkAndShowDialog(BuildContext context) async {
    try {
      final latestTag = await fetchLatestTag();
      if (latestTag == null || latestTag.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not check for updates.')),
          );
        }
        return;
      }

      final newer = isNewer(latestTag, AppVersion.versionName);
      if (!newer) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 18),
                  SizedBox(width: 8),
                  Text('You have the latest version.'),
                ],
              ),
            ),
          );
        }
        return;
      }

      final downloadUrl =
          '${AppVersion.downloadBaseUrl}/Apex-Agent-$latestTag.apk';
      if (context.mounted) {
        showUpdateDialog(context, latestTag: latestTag, downloadUrl: downloadUrl);
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Network error checking for updates.')),
        );
      }
    }
  }
}
