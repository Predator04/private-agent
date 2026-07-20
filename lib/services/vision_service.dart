import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'screen_automation_service.dart';
import '../models/agent_action.dart';

/// Result from a vision-based screen analysis.
class VisionScreenResult {
  final String description;
  final String base64Image;
  final bool hadError;

  VisionScreenResult({
    required this.description,
    required this.base64Image,
    this.hadError = false,
  });
}

/// Optional vision-based screen reading service.
///
/// When the accessibility tree is sparse (WebViews, Canvas apps, games),
/// this service takes a screenshot and sends it to a vision-capable model
/// for analysis. It supplements (not replaces) the accessibility tree.
///
/// Usage: call [analyzeScreen] when the task executor detects sparse
/// accessibility output, then pass the result alongside the accessibility
/// dump in the AI prompt.
class VisionService {
  final ScreenAutomationService _screenService;

  /// Whether a vision-capable model is configured.
  /// Set via [configure] before first use.
  bool _isAvailable = false;

  /// The model name to use for vision (e.g. "openai/gpt-4o", "glm-5.2-vision")
  String _visionModel = '';

  // API settings are read from SharedPreferences (same keys as AiService).
  String _apiKey = '';
  String _baseUrl = '';

  VisionService(this._screenService);

  /// Configure vision from the same SharedPreferences the AI service uses.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _apiKey = prefs.getString('api_key') ?? '';
    _baseUrl = prefs.getString('api_base_url') ?? 'https://api.deepseek.com';
    _visionModel = prefs.getString('vision_model') ?? _visionModel;
    _isAvailable = _apiKey.isNotEmpty &&
        _visionModel.isNotEmpty &&
        _screenService.hasScreenshotCapability();

    if (_isAvailable) {
      developer.log(
        'Vision service available: $_visionModel',
        name: 'VisionService',
      );
    }
  }

  /// Whether a vision-capable model is configured and screenshots work.
  bool get isAvailable => _isAvailable;

  /// The vision model name (shown in settings).
  String get visionModel => _visionModel;

  /// Save a custom vision model (called from Settings screen).
  Future<void> saveVisionModel(String model) async {
    _visionModel = model;
    _isAvailable = _apiKey.isNotEmpty && _visionModel.isNotEmpty;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vision_model', model);
  }

  /// Take a screenshot and ask the vision model what's on screen.
  ///
  /// Returns a text description of the screen contents, suitable for
  /// inclusion in the task executor's prompt alongside the accessibility dump.
  /// Returns null if vision is unavailable or the call fails.
  Future<VisionScreenResult?> analyzeScreen(String task) async {
    if (!_isAvailable) return null;

    try {
      // 1. Capture screenshot as base64
      final base64Image = await _screenService.takeScreenshot();
      if (base64Image == null || base64Image.isEmpty) {
        developer.log(
          'Vision: screenshot capture failed (needs Android 11+)',
          name: 'VisionService',
        );
        return null;
      }

      // 2. Build the vision prompt
      final systemPrompt = '''
You are a phone screen reader. Describe what you see on this phone screen.
Focus on: visible text, buttons, icons, input fields, lists, and any UI elements relevant to the user's goal.
Be concise — list only interactive elements and their approximate positions.
If you recognize the app, name it.
''';

      final userPrompt = '''
User goal: $task

Describe what's visible on this phone screen. List each interactive element
with its text/label and approximate position (top, bottom, left, right, center).
Focus on elements the user would need to complete their goal.
''';

      // 3. Send to the vision model
      String requestUrl = _baseUrl;
      if (!requestUrl.endsWith('/chat/completions')) {
        if (requestUrl.endsWith('/')) {
          requestUrl = '${requestUrl}chat/completions';
        } else {
          requestUrl = '$requestUrl/chat/completions';
        }
      }

      final response = await http
          .post(
            Uri.parse(requestUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_apiKey',
              'HTTP-Referer': 'https://github.com/Predator04/private-agent',
              'X-Title': 'Apex Agent',
            },
            body: jsonEncode({
              'model': _visionModel,
              'messages': [
                {'role': 'system', 'content': systemPrompt},
                {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': userPrompt},
                    {
                      'type': 'image_url',
                      'image_url': {
                        'url': 'data:image/jpeg;base64,$base64Image',
                        'detail': 'low', // low detail saves tokens
                      },
                    },
                  ],
                },
              ],
              'max_tokens': 1024,
              'temperature': 0.1,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        developer.log(
          'Vision API error (${response.statusCode}): ${response.body}',
          name: 'VisionService',
        );
        return VisionScreenResult(
          description: '',
          base64Image: base64Image,
          hadError: true,
        );
      }

      final data = jsonDecode(response.body);
      final content = data['choices']?[0]?['message']?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        return VisionScreenResult(
          description: '',
          base64Image: base64Image,
          hadError: true,
        );
      }

      developer.log(
        'Vision analysis result (${content.length} chars)',
        name: 'VisionService',
      );

      return VisionScreenResult(
        description: content.trim(),
        base64Image: base64Image,
      );
    } catch (e) {
      developer.log('Vision service error: $e', name: 'VisionService');
      return null;
    }
  }

  /// Check if the accessibility tree seems sparse enough to warrant vision.
  ///
  /// Returns true if the screen dump has very few text-bearing elements,
  /// suggesting a WebView, Canvas, or custom-drawn UI.
  static bool isScreenDumpSparse(String screenDump) {
    if (screenDump.length < 100) return true; // Very short = definitely sparse
    if (screenDump.length > 500) return false; // Plenty of content, skip vision
    // Between 100-500 chars: count the number of text entries
    final textCount = RegExp(r'"([^"]+)"').allMatches(screenDump).length;
    return textCount < 3; // Fewer than 3 text elements = sparse
  }
}
