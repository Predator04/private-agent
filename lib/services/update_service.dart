import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import '../config/app_version.dart';

/// Manages checking for updates from GitHub releases.
/// Supports "skip this version" so the dialog doesn't re-prompt,
/// and downloads the APK directly inside the app.
class UpdateService {
  static const _skippedVersionKey = 'skipped_update_version';

  /// Check GitHub for the latest release tag.
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

  /// True if [latestTag] is a higher version than [currentVersion].
  static bool isNewer(String latestTag, String currentVersion) {
    final tagVer = latestTag.replaceFirst('v', '').trim();
    final curVer = currentVersion.split('+').first.trim();
    return _compareVersions(tagVer, curVer) > 0;
  }

  static int _compareVersions(String a, String b) {
    final aParts = a.split('.').map(int.tryParse).whereType<int>().toList();
    final bParts = b.split('.').map(int.tryParse).whereType<int>().toList();
    final maxLen =
        aParts.length > bParts.length ? aParts.length : bParts.length;
    for (int i = 0; i < maxLen; i++) {
      final aVal = i < aParts.length ? aParts[i] : 0;
      final bVal = i < bParts.length ? bParts[i] : 0;
      if (aVal != bVal) return aVal - bVal;
    }
    return 0;
  }

  static Future<String?> getSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_skippedVersionKey);
  }

  static Future<void> skipVersion(String tag) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, tag);
  }

  static Future<void> clearSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_skippedVersionKey);
  }

  /// Silent check — returns whether a newer (non-skipped) version exists.
  static Future<({
    String? latestTag,
    bool newerExists,
    String? downloadUrl,
  })> silentCheck() async {
    final latestTag = await fetchLatestTag();
    if (latestTag == null || latestTag.isEmpty) {
      return (latestTag: null, newerExists: false, downloadUrl: null);
    }
    if (!isNewer(latestTag, AppVersion.versionName)) {
      return (latestTag: latestTag, newerExists: false, downloadUrl: null);
    }
    final skipped = await getSkippedVersion();
    if (skipped == latestTag) {
      return (latestTag: latestTag, newerExists: false, downloadUrl: null);
    }
    return (
      latestTag: latestTag,
      newerExists: true,
      downloadUrl:
          '${AppVersion.downloadBaseUrl}/Apex-Agent-$latestTag.apk',
    );
  }

  /// Stream the APK to a local file. Returns the file path on success.
  static Future<String?> downloadApk(
    String url,
    String tagName, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final fileName = 'Apex-Agent-$tagName.apk';
      final filePath = '${dir.path}/$fileName';

      final existing = File(filePath);
      if (existing.existsSync()) await existing.delete();

      final request = http.Request('GET', Uri.parse(url));
      final streamed = await http.Client().send(request);
      if (streamed.statusCode != 200) return null;

      final contentLength = streamed.contentLength ?? 0;
      final file = File(filePath);
      final sink = file.openWrite();
      int received = 0;

      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0 && onProgress != null) {
          onProgress(received / contentLength);
        }
      }
      await sink.flush();
      await sink.close();
      return filePath;
    } catch (_) {
      return null;
    }
  }

  /// Open the Android package installer for the downloaded APK.
  /// Uses a content:// URI via FileProvider (Android 7+).
  static Future<bool> installApk(String filePath) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;

      final cleanPath = filePath.replaceAll(RegExp(r'^/+'), '');
      final contentUri =
          'content://com.predator04.apexagent.fileprovider/root/$cleanPath';

      final intent = AndroidIntent(
        action: 'android.intent.action.INSTALL_PACKAGE',
        data: contentUri,
        flags: [
          Flag.FLAG_ACTIVITY_NEW_TASK,
          Flag.FLAG_GRANT_READ_URI_PERMISSION,
        ],
      );
      await intent.launch();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Show the update dialog with three phases: prompt → downloading → ready.
  static void showUpdateDialog(
    BuildContext context, {
    required String latestTag,
    required String downloadUrl,
  }) {
    // Track download state outside the builder so we can share it
    String? downloadedPath;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        // Phase 0 = prompt, 1 = downloading, 2 = ready
        int phase = downloadedPath != null ? 2 : 0;
        double dlProgress = 0.0;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isPrompt = phase == 0;
            final isDownloading = phase == 1;
            final isReady = phase == 2;

            return AlertDialog(
              title: Row(
                children: [
                  Icon(
                    isReady
                        ? Icons.check_circle
                        : isDownloading
                            ? Icons.downloading
                            : Icons.system_update_rounded,
                    color: isReady ? Colors.green : Colors.amber,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isReady
                        ? 'Ready to Install'
                        : isDownloading
                            ? 'Downloading...'
                            : 'Update Available',
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isPrompt) ...[
                      Text(
                        'Version $latestTag is available!',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Download and install directly in the app.\n'
                        'You will need to tap "Install" on the next screen.',
                        style: TextStyle(fontSize: 14),
                      ),
                    ] else if (isDownloading) ...[
                      LinearProgressIndicator(
                        value: dlProgress > 0 ? dlProgress : null,
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          dlProgress > 0
                              ? '${(dlProgress * 100).toInt()}%'
                              : 'Starting download...',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ] else ...[
                      const Row(
                        children: [
                          Icon(Icons.check_circle,
                              color: Colors.green, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'APK downloaded successfully!',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap "Install" to open the package installer.\n'
                        'You may need to allow "Install unknown apps"\n'
                        'from Apex Agent in system Settings.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                if (!isDownloading)
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                if (isPrompt) ...[
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      skipVersion(latestTag);
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Version $latestTag skipped. '
                            'Check Settings to re-enable.',
                          ),
                        ),
                      );
                    },
                    child: const Text('Skip This Version'),
                  ),
                  FilledButton.icon(
                    onPressed: () async {
                      setDialogState(() {
                        phase = 1;
                        dlProgress = 0.0;
                      });
                      final path = await downloadApk(
                        downloadUrl,
                        latestTag,
                        onProgress: (p) {
                          setDialogState(() => dlProgress = p);
                        },
                      );
                      if (path != null && context.mounted) {
                        downloadedPath = path;
                        setDialogState(() => phase = 2);
                      } else if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Download failed. Try again.'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download & Install'),
                  ),
                ],
                if (isReady)
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      if (downloadedPath != null) {
                        installApk(downloadedPath!);
                      }
                    },
                    icon: const Icon(Icons.install_mobile, size: 18),
                    label: const Text('Install'),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// Check for update and show the dialog (used by auto-check and manual button).
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

      if (!isNewer(latestTag, AppVersion.versionName)) {
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
        showUpdateDialog(
          context,
          latestTag: latestTag,
          downloadUrl: downloadUrl,
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Network error checking for updates.'),
          ),
        );
      }
    }
  }
}
