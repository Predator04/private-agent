import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:path_provider/path_provider.dart';

/// Detailed step-level trace for debugging AI behavior.
class StepTrace {
  final int step;
  final String action;
  final Map<String, dynamic> params;
  final String reasoning;
  final bool isComplete;
  final String aiResponse;
  final String screenDump;
  final String result;
  final bool success;
  final int durationMs;
  final String loopHint;

  StepTrace({
    required this.step,
    required this.action,
    required this.params,
    required this.reasoning,
    required this.isComplete,
    required this.aiResponse,
    required this.screenDump,
    required this.result,
    required this.success,
    required this.durationMs,
    this.loopHint = '',
  });

  Map<String, dynamic> toJson() => {
        'step': step,
        'action': action,
        'params': params,
        'reasoning': reasoning,
        'is_complete': isComplete,
        'ai_response': aiResponse,
        'screen_dump': screenDump,
        'result': result,
        'success': success,
        'duration_ms': durationMs,
        'loop_hint': loopHint,
      };
}

class TaskHistoryLogger {
  static Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/task_history.jsonl');
  }

  /// Appends a task execution record to the history file
  static Future<void> logTask(
    String goal,
    String status,
    int totalTokens,
    int steps,
    List<String> trace, {
    List<StepTrace>? detailedSteps,
    String? screenshotBase64,
  }) async {
    try {
      final file = await _localFile;

      // Rotate: keep last 200 entries if file exceeds 5MB
      if (await file.exists() && await file.length() > 5 * 1024 * 1024) {
        final lines = await file.readAsLines();
        if (lines.length > 200) {
          await file.writeAsString(
            lines.skip(lines.length - 200).map((l) => '$l\n').join(),
          );
        }
      }

      final data = {
        "goal": goal.trim(),
        "status": status,
        "total_tokens": totalTokens,
        "steps_taken": steps,
        "trace": trace,
        "detailed_steps":
            detailedSteps?.map((s) => s.toJson()).toList() ?? [],
        "timestamp": DateTime.now().toIso8601String(),
        if (screenshotBase64 != null) "screenshot": screenshotBase64,
      };

      await file.writeAsString('${jsonEncode(data)}\n', mode: FileMode.append);
    } catch (e) {
      developer.log('Failed to write task history: $e', name: 'ApexAgent');
    }
  }

  /// Reads the entire task history file for previewing
  static Future<List<Map<String, dynamic>>> readHistory() async {
    try {
      final file = await _localFile;
      if (!await file.exists()) return [];

      final lines = await file.readAsLines();
      return lines
          .where((line) => line.trim().isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList()
          .reversed
          .toList(); // newest first
    } catch (e) {
      developer.log('Failed to read task history: $e', name: 'ApexAgent');
      return [];
    }
  }

  /// Clears the task history file
  static Future<void> clearHistory() async {
    try {
      final file = await _localFile;
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      developer.log('Failed to clear task history: $e', name: 'ApexAgent');
    }
  }

  /// Calculates analytics from task history
  static Future<Map<String, dynamic>> getAnalytics() async {
    final history = await readHistory();
    if (history.isEmpty) {
      return {
        'totalTasks': 0,
        'successRate': 0.0,
        'successCount': 0,
        'failedCount': 0,
        'totalTokens': 0,
      };
    }

    int successCount = 0;
    int failedCount = 0;
    int totalTokens = 0;

    for (final task in history) {
      if (task['status'] == 'Success') {
        successCount++;
      } else if (task['status'] == 'Failed' || task['status'] == 'Cancelled') {
        failedCount++;
      }
      // Sum total_tokens across all tasks (for cost estimation)
      final tokens = task['total_tokens'];
      if (tokens is num) {
        totalTokens += tokens.toInt();
      }
    }

    return {
      'totalTasks': history.length,
      'successRate': successCount / history.length,
      'successCount': successCount,
      'failedCount': failedCount,
      'totalTokens': totalTokens,
    };
  }
}
