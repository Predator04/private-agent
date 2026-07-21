import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../services/ai_service.dart';
import '../services/shizuku_service.dart';
import '../services/screen_automation_service.dart';
import '../services/telegram_service.dart';
import 'task_history_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../config/feature_flags.dart';
import '../config/app_version.dart';
import '../services/update_service.dart';
import '../services/task_history_logger.dart';

class SettingsScreen extends StatefulWidget {
  final AiService aiService;
  final ShizukuService shizukuService;
  final ScreenAutomationService screenAutomationService;
  final TelegramService telegramService;

  const SettingsScreen({
    super.key,
    required this.aiService,
    required this.shizukuService,
    required this.screenAutomationService,
    required this.telegramService,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late TextEditingController _apiKeyController;
  late TextEditingController _baseUrlController;
  late TextEditingController _modelController;
  late TextEditingController _visionModelController;
  late TextEditingController _telegramTokenController;
  bool _obscureKey = true;
  bool _telegramEnabled = false;
  double _maxSteps = 10;
  bool _disableMaxSteps = false;
  late TextEditingController _maxTokensController;
  double _temperature = 1.0;
  bool _useScreenCompression = true;
  bool _useSystemPrompt = true;
  bool _floatingIconEnabled = false;
  bool _godMode = false;
  bool _isOverlayPermissionGranted = false;

  // Scheduled Tasks (Feature 2)
  List<Map<String, dynamic>> _scheduledTasks = [];

  // Analytics cache (Feature 1) — loaded in initState, refreshed on demand
  Map<String, dynamic>? _taskAnalytics;

  final Map<String, PermissionStatus> _permissions = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _apiKeyController = TextEditingController(text: widget.aiService.apiKey);
    _baseUrlController = TextEditingController(text: widget.aiService.baseUrl);
    _modelController = TextEditingController(text: widget.aiService.model);
    _visionModelController = TextEditingController(
      text: '',
    );
    _loadVisionModel();
    _telegramTokenController = TextEditingController(
      text: widget.telegramService.botToken,
    );
    _telegramEnabled = widget.telegramService.isEnabled;
    _maxSteps = widget.aiService.rawMaxSteps.toDouble();
    _disableMaxSteps = widget.aiService.disableMaxSteps;
    _temperature = widget.aiService.temperature;
    _maxTokensController = TextEditingController(
      text: widget.aiService.maxTokens.toString(),
    );
    _useScreenCompression = widget.aiService.useScreenCompression;
    _useSystemPrompt = widget.aiService.useSystemPrompt;
    _godMode = widget.aiService.godMode;

    // Auto-save listeners
    _apiKeyController.addListener(_autoSave);
    _baseUrlController.addListener(_autoSave);
    _modelController.addListener(_autoSave);
    _visionModelController.addListener(_autoSave);
    _telegramTokenController.addListener(_autoSave);
    _maxTokensController.addListener(_autoSave);

    _checkPermissions();
    if (FeatureFlags.floatingOverlayEnabled) {
      _checkOverlayStatus();
    }
    _loadScheduledTasks();
    _refreshAnalytics();
  }

  /// Loads scheduled tasks from SharedPreferences (key: scheduled_tasks).
  Future<void> _loadScheduledTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('scheduled_tasks');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final tasks = decoded
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          if (mounted) {
            setState(() {
              _scheduledTasks = tasks;
            });
          }
        }
      }
    } catch (e) {
      developer.log('Failed to load scheduled tasks: $e',
          name: 'ApexAgent');
    }
  }

  /// Persists scheduled tasks to SharedPreferences.
  Future<void> _saveScheduledTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('scheduled_tasks', jsonEncode(_scheduledTasks));
    } catch (e) {
      developer.log('Failed to save scheduled tasks: $e',
          name: 'ApexAgent');
    }
  }

  /// Refreshes the cached analytics from TaskHistoryLogger.
  Future<void> _refreshAnalytics() async {
    try {
      final analytics = await TaskHistoryLogger.getAnalytics();
      if (mounted) {
        setState(() {
          _taskAnalytics = analytics;
        });
      }
    } catch (e) {
      developer.log('Failed to load analytics: $e', name: 'ApexAgent');
    }
  }

  Future<void> _loadVisionModel() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _visionModelController.text = prefs.getString('vision_model') ?? '';
      });
    }
  }

  Future<void> _checkOverlayStatus() async {
    bool isActive = await FlutterOverlayWindow.isActive();
    bool isGranted = await FlutterOverlayWindow.isPermissionGranted();
    if (mounted) {
      setState(() {
        _floatingIconEnabled = isActive;
        _isOverlayPermissionGranted = isGranted;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _apiKeyController.removeListener(_autoSave);
    _baseUrlController.removeListener(_autoSave);
    _modelController.removeListener(_autoSave);
    _visionModelController.removeListener(_autoSave);
    _telegramTokenController.removeListener(_autoSave);
    _maxTokensController.removeListener(_autoSave);
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _visionModelController.dispose();
    _telegramTokenController.dispose();
    _maxTokensController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
      if (FeatureFlags.floatingOverlayEnabled) {
        _checkOverlayStatus();
      }
    }
  }

  Future<void> _checkPermissions() async {
    final perms = {
      'Microphone': Permission.microphone,
      'Contacts': Permission.contacts,
      'Phone': Permission.phone,
      'SMS': Permission.sms,
      'Notifications': Permission.notification,
    };

    for (final entry in perms.entries) {
      _permissions[entry.key] = await entry.value.status;
    }
    final overlayGranted = FeatureFlags.floatingOverlayEnabled
        ? await FlutterOverlayWindow.isPermissionGranted()
        : false;
    if (mounted) {
      setState(() {
        _isOverlayPermissionGranted = overlayGranted;
      });
    }
  }

  Future<void> _requestPermission(String name, Permission permission) async {
    final status = await permission.request();
    setState(() => _permissions[name] = status);
  }

  void _autoSave() {
    widget.aiService.saveSettings(
      apiKey: _apiKeyController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
    );

    // Save vision model to SharedPreferences
    final prefs = SharedPreferences.getInstance();
    prefs.then((p) {
      p.setString('vision_model', _visionModelController.text.trim());
    });

    widget.telegramService.saveSettings(
      botToken: _telegramTokenController.text.trim(),
      isEnabled: _telegramEnabled,
    );

    widget.aiService.saveMaxSteps(_maxSteps.toInt());
    widget.aiService.saveDisableMaxSteps(_disableMaxSteps);
    widget.aiService.saveAdvancedSettings(
      temperature: _temperature,
      maxTokens: int.tryParse(_maxTokensController.text) ?? 1024,
      useScreenCompression: _useScreenCompression,
      useSystemPrompt: _useSystemPrompt,
    );
  }

  Future<void> _fetchModels() async {
    final baseUrl = _baseUrlController.text.trim();
    final apiKey = _apiKeyController.text.trim();

    if (baseUrl.isEmpty || apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter Base URL and API Key first.'),
        ),
      );
      return;
    }

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    final models = await widget.aiService.fetchAvailableModels(baseUrl, apiKey);

    // Hide loading
    if (mounted) Navigator.pop(context);

    if (models.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No models found or error fetching models.'),
          ),
        );
      }
      return;
    }

    if (mounted) {
      final isNvidia = AiService.isNvidiaBaseUrl(baseUrl);
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            isNvidia ? 'Select a Free NVIDIA Model' : 'Select a Model',
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: ListView.builder(
              itemCount: models.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(models[index]),
                  onTap: () {
                    setState(() {
                      _modelController.text = models[index];
                    });
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildSettingsCard({
    required IconData icon,
    required String title,
    String? subtitle,
    required List<Widget> children,
    required bool isDark,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    color: Theme.of(context).primaryColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF475569),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }

  InputDecoration _buildInputDecoration({
    required String labelText,
    required String hintText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      labelStyle: TextStyle(
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      hintStyle: TextStyle(
        color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
        fontSize: 13,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 1.8,
        ),
      ),
      floatingLabelBehavior: FloatingLabelBehavior.auto,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          // 1. Appearance Card
          _buildSettingsCard(
            icon: Icons.palette_outlined,
            title: 'Appearance',
            subtitle: 'Choose your preferred color theme',
            isDark: isDark,
            children: [
              ValueListenableBuilder<ThemeMode>(
                valueListenable: themeNotifier,
                builder: (context, currentMode, _) {
                  return SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      style: SegmentedButton.styleFrom(
                        selectedBackgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary,
                        selectedForegroundColor: Colors.white,
                        backgroundColor: isDark
                            ? const Color(0xFF1E293B)
                            : Colors.white,
                        foregroundColor: isDark ? Colors.white : Colors.black87,
                        side: BorderSide(
                          color: isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                      segments: [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: const Text(
                            'System',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          icon: const Icon(Icons.brightness_auto, size: 16),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: const Text(
                            'Light',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          icon: const Icon(Icons.light_mode, size: 16),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: const Text(
                            'Dark',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          icon: const Icon(Icons.dark_mode, size: 16),
                        ),
                      ],
                      selected: {currentMode},
                      onSelectionChanged: (Set<ThemeMode> newSelection) async {
                        final mode = newSelection.first;
                        themeNotifier.value = mode;
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('themeMode', mode.name);
                      },
                    ),
                  );
                },
              ),
            ],
          ),

          // 2. AI Engine Config Card
          _buildSettingsCard(
            icon: Icons.psychology_outlined,
            title: 'AI Engine Configuration',
            subtitle: 'Supports any OpenAI-compatible API endpoint',
            isDark: isDark,
            children: [
              TextField(
                controller: _apiKeyController,
                decoration: _buildInputDecoration(
                  labelText: 'API Key',
                  hintText: 'sk-...',
                  prefixIcon: const Icon(Icons.key_rounded, size: 18),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureKey ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
                obscureText: _obscureKey,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _baseUrlController,
                decoration: _buildInputDecoration(
                  labelText: 'API Base URL',
                  hintText: 'https://api.deepseek.com',
                  prefixIcon: const Icon(Icons.dns_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ActionChip(
                    label: const Text(
                      'Local Server',
                      style: TextStyle(fontSize: 11),
                    ),
                    tooltip: 'For local Llama.cpp or LM Studio',
                    onPressed: () =>
                        _baseUrlController.text = 'http://192.168.1.X:8080/v1',
                  ),
                  ActionChip(
                    label: const Text(
                      'Ollama Cloud',
                      style: TextStyle(fontSize: 11),
                    ),
                    onPressed: () {
                      _baseUrlController.text = 'https://ollama.com/v1';
                      _modelController.text = 'gemma3:4b';
                    },
                  ),
                  ActionChip(
                    label: const Text(
                      'DeepSeek',
                      style: TextStyle(fontSize: 11),
                    ),
                    onPressed: () =>
                        _baseUrlController.text = 'https://api.deepseek.com',
                  ),
                  ActionChip(
                    label: const Text('Groq', style: TextStyle(fontSize: 11)),
                    onPressed: () => _baseUrlController.text =
                        'https://api.groq.com/openai/v1',
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.memory_rounded, size: 16),
                    label: const Text('NVIDIA', style: TextStyle(fontSize: 11)),
                    tooltip: 'NVIDIA NIM free endpoints',
                    onPressed: () {
                      _baseUrlController.text = AiService.nvidiaBaseUrl;
                      _modelController.text = AiService.nvidiaDefaultModel;
                    },
                  ),
                  ActionChip(
                    label: const Text('Custom', style: TextStyle(fontSize: 11)),
                    tooltip: 'Clear fields',
                    onPressed: () {
                      _baseUrlController.clear();
                      _apiKeyController.clear();
                      _modelController.clear();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _modelController,
                      decoration: _buildInputDecoration(
                        labelText: 'Model',
                        hintText: 'deepseek-chat',
                        prefixIcon: const Icon(
                          Icons.smart_toy_rounded,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _fetchModels,
                    icon: const Icon(
                      Icons.cloud_download,
                      size: 18,
                      color: Colors.white,
                    ),
                    label: const Text(
                      'Fetch',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // 2b. Vision Model Config (optional supplement)
          _buildSettingsCard(
            icon: Icons.image_search_outlined,
            title: 'Vision Model (Optional)',
            subtitle: 'Used when Accessibility tree is sparse (WebViews, Canvas apps)',
            isDark: isDark,
            children: [
              TextField(
                controller: _visionModelController,
                decoration: _buildInputDecoration(
                  labelText: 'Vision Model Name',
                  hintText: 'openai/gpt-4o',
                  prefixIcon: const Icon(Icons.image_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Leave blank to disable vision fallback.\n'
                'Vision requires a multimodal model and Android 11+.\n'
                'Recommended: openai/gpt-4o, gemini-2.0-flash, or llama-3.2-11b-vision',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                ),
              ),
            ],
          ),

          // 3. Parameters & Tuning Card
          _buildSettingsCard(
            icon: Icons.tune_outlined,
            title: 'Tuning & Boundaries',
            subtitle: 'Configure LLM agent parameters',
            isDark: isDark,
            children: [
              SwitchListTile(
                title: const Text('Disable Maximum Steps'),
                subtitle: const Text(
                  '⚠️ Can cause infinite loops.',
                  style: TextStyle(color: Colors.orange, fontSize: 12),
                ),
                value: _disableMaxSteps,
                onChanged: (bool value) {
                  setState(() {
                    _disableMaxSteps = value;
                  });
                  _autoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (!_disableMaxSteps) ...[
                const SizedBox(height: 8),
                Text(
                  'Maximum Steps Per Task: ${_maxSteps.toInt()}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
                Slider(
                  value: _maxSteps,
                  min: 5,
                  max: 50,
                  divisions: 45,
                  label: _maxSteps.toInt().toString(),
                  onChanged: (value) {
                    setState(() {
                      _maxSteps = value;
                    });
                  },
                  onChangeEnd: (value) {
                    _autoSave();
                  },
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _maxTokensController,
                keyboardType: TextInputType.number,
                decoration: _buildInputDecoration(
                  labelText: 'Context Limit (Max Tokens)',
                  hintText: '1024',
                  prefixIcon: const Icon(Icons.token_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Temperature: ${_temperature.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
              ),
              Slider(
                value: _temperature,
                min: 0.0,
                max: 2.0,
                divisions: 20,
                label: _temperature.toStringAsFixed(2),
                onChanged: (value) {
                  setState(() {
                    _temperature = value;
                  });
                },
                onChangeEnd: (value) {
                  _autoSave();
                },
              ),
            ],
          ),

          // 4. Behavior & Extensions Card
          _buildSettingsCard(
            icon: Icons.extension_outlined,
            title: 'Behavior & Extensions',
            subtitle: 'Additional feature flags and overlay options',
            isDark: isDark,
            children: [
              SwitchListTile(
                title: const Text('Use Screen Compression'),
                subtitle: const Text(
                  'Removes duplicate elements to save tokens',
                ),
                value: _useScreenCompression,
                onChanged: (bool value) {
                  setState(() {
                    _useScreenCompression = value;
                  });
                  _autoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: const Text('Send System Prompt'),
                subtitle: const Text('Turn off for custom LoRA fine-tunes'),
                value: _useSystemPrompt,
                onChanged: (bool value) {
                  setState(() {
                    _useSystemPrompt = value;
                  });
                  _autoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: Row(
                  children: [
                    const Text('God Mode'),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.bolt_rounded,
                      size: 18,
                      color: _godMode ? Colors.amber : Colors.grey,
                    ),
                  ],
                ),
                subtitle: const Text('AI will obey every command without refusal or limits'),
                value: _godMode,
                activeColor: Colors.amber.shade700,
                activeTrackColor: Colors.amber.shade200,
                onChanged: (bool value) async {
                  setState(() => _godMode = value);
                  await widget.aiService.saveGodMode(value);
                  _autoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (FeatureFlags.floatingOverlayEnabled)
                SwitchListTile(
                  title: const Text('Enable Floating Agent Icon'),
                  subtitle: const Text('Assign tasks without opening the app'),
                  value: _floatingIconEnabled,
                  onChanged: (val) async {
                    if (val) {
                      bool? isGranted =
                          await FlutterOverlayWindow.isPermissionGranted();
                      if (isGranted != true) {
                        bool? result =
                            await FlutterOverlayWindow.requestPermission();
                        if (result != true) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Permission to draw over other apps is required.',
                                ),
                              ),
                            );
                          }
                          return;
                        }
                      }
                      if (await FlutterOverlayWindow.isActive() == false) {
                        await FlutterOverlayWindow.showOverlay(
                          enableDrag: true,
                          overlayTitle: "Apex Agent",
                          overlayContent: "Floating Assistant",
                          flag: OverlayFlag.focusPointer,
                          alignment: OverlayAlignment.centerRight,
                          visibility: NotificationVisibility.visibilitySecret,
                          positionGravity: PositionGravity.auto,
                          startPosition: const OverlayPosition(0, 200),
                          width: 56,
                          height: 56,
                        );
                      }
                    } else {
                      if (await FlutterOverlayWindow.isActive() == true) {
                        await FlutterOverlayWindow.closeOverlay();
                      }
                    }
                    setState(() => _floatingIconEnabled = val);
                    _autoSave();
                  },
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),

          // 5. Telegram Remote Access Card
          _buildSettingsCard(
            icon: Icons.send_and_archive_outlined,
            title: 'Telegram Remote Access',
            subtitle: 'Control your agent remotely from anywhere',
            isDark: isDark,
            children: [
              TextField(
                controller: _telegramTokenController,
                decoration: _buildInputDecoration(
                  labelText: 'Telegram Bot Token',
                  hintText: '123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11',
                  prefixIcon: const Icon(Icons.send_rounded, size: 18),
                ),
              ),
              SwitchListTile(
                title: const Text('Enable Telegram Bot'),
                subtitle: const Text('Allows remote control via Telegram chat'),
                value: _telegramEnabled,
                onChanged: (val) {
                  setState(() => _telegramEnabled = val);
                  _autoSave();
                },
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),

          // 6. Accessibility Screen Control Card
          _buildSettingsCard(
            icon: Icons.visibility_outlined,
            title: 'Screen Control (Accessibility)',
            subtitle: 'Required to read screen and perform automated clicks',
            isDark: isDark,
            children: [_buildAccessibilityCard()],
          ),

          // 7. System Permissions Card
          _buildSettingsCard(
            icon: Icons.security_outlined,
            title: 'App Permissions',
            subtitle: 'Required for automation, microphone, and contacts',
            isDark: isDark,
            children: _buildPermissionTiles(),
          ),

          // 8. Task History Card
          _buildSettingsCard(
            icon: Icons.history_outlined,
            title: 'Execution logs',
            subtitle: 'View history of tasks and token analytics',
            isDark: isDark,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('View Task History'),
                subtitle: const Text(
                  'Access complete trace of execution steps',
                ),
                trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const TaskHistoryScreen(),
                    ),
                  );
                  // Refresh analytics when returning from history screen
                  if (mounted) _refreshAnalytics();
                },
              ),
              const Divider(),
              _buildAnalyticsStats(isDark),
            ],
          ),

          // 8b. Scheduled Tasks Card
          _buildSettingsCard(
            icon: Icons.schedule_outlined,
            title: 'Scheduled Tasks',
            subtitle: 'Run goals automatically on a recurring schedule',
            isDark: isDark,
            children: _buildScheduledTasksChildren(isDark),
          ),

          // 9. About / Links Card
          _buildSettingsCard(
            icon: Icons.info_outline_rounded,
            title: 'About Apex Agent',
            subtitle: 'Resources and repository access',
            isDark: isDark,
            children: [
              // Version & Update row
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Version ${AppVersion.versionName}'),
                subtitle: const Text('Check for updates on GitHub'),
                leading: const Icon(Icons.info_outline_rounded),
                trailing: TextButton.icon(
                  onPressed: () => UpdateService.checkAndShowDialog(context),
                  label: const Text('Check'),
                  icon: const Icon(Icons.system_update_rounded, size: 16),
                ),
              ),
              const Divider(),
              // Clear Skipped Update
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Clear Skipped Update'),
                subtitle: const Text('Re-enable update prompt for skipped version'),
                leading: const Icon(Icons.restart_alt_rounded),
                onTap: () async {
                  await UpdateService.clearSkippedVersion();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Skipped version cleared. '
                            'You will be prompted on next check.'),
                      ),
                    );
                  }
                },
              ),
              const Divider(),
              // What's New / Changelog
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text("What's New"),
                subtitle: const Text('View changelog for this version'),
                leading: const Icon(Icons.sticky_note_2_rounded),
                onTap: () => _showChangelogDialog(context),
              ),
              const Divider(),
              // Task History
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Task History'),
                subtitle: const Text('View detailed execution logs'),
                leading: const Icon(Icons.history_rounded),
                onTap: () => _showTaskHistory(context),
              ),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Project Repository'),
                subtitle: const Text('View source code on GitHub'),
                leading: const Icon(Icons.code_rounded),
                onTap: () {
                  launchUrl(
                    Uri.parse('https://github.com/Predator04/private-agent'),
                    mode: LaunchMode.externalApplication,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showChangelogDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.sticky_note_2_rounded, size: 24),
            SizedBox(width: 8),
            Text("What's New"),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              _changelogSection(
                'v1.6.0',
                'Reduced default max steps 15→10, stronger loop prevention, detailed task logging',
              ),
              _changelogSection(
                'v1.5.0',
                'Fixed Missing type parameter crash, switched to ACTION_VIEW for install',
              ),
              _changelogSection(
                'v1.4.0',
                'Silent notifications, AI avoids voice search, speed improvements, YouTube links removed',
              ),
              _changelogSection(
                'v1.3.0',
                'Memory leak fixes, Disable Max Steps toggle, notification/crash fixes',
              ),
              _changelogSection(
                'v1.2.0',
                'Speed boost (delays cut 55-65%), persistent task notification, toast every step',
              ),
              _changelogSection(
                'v1.1.0',
                'In-app version display, auto-update check, Download & Install from within app',
              ),
              _changelogSection(
                'v1.0.2',
                'Initial release: God Mode, Agent default, mute button, rebrand to Apex Agent',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _changelogSection(String version, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              version,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: Colors.amber,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showTaskHistory(BuildContext context) async {
    final history = await TaskHistoryLogger.readHistory();
    if (!context.mounted) return;

    if (history.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No task history yet.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.history_rounded, size: 24),
            SizedBox(width: 8),
            Text('Task History'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: ListView.builder(
            itemCount: history.length + 1, // +1 for clear button
            itemBuilder: (ctx, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextButton.icon(
                    onPressed: () async {
                      await TaskHistoryLogger.clearHistory();
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('History cleared.')),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.delete_sweep, size: 18),
                    label: const Text('Clear All History'),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                  ),
                );
              }

              final task = history[i - 1];
              final goal = task['goal'] as String? ?? 'Unknown';
              final status = task['status'] as String? ?? '?';
              final steps = task['steps_taken'] ?? 0;
              final tokens = task['total_tokens'] ?? 0;
              final detailedSteps = task['detailed_steps'] as List<dynamic>? ?? [];
              final hasTaskScreenshot = task['screenshot'] != null;

              final statusIcon = status == 'Success'
                  ? Icons.check_circle
                  : status == 'Cancelled'
                      ? Icons.cancel
                      : Icons.error;
              final statusColor = status == 'Success'
                  ? Colors.green
                  : status == 'Cancelled'
                      ? Colors.orange
                      : Colors.red;

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ExpansionTile(
                  leading: Icon(statusIcon, color: statusColor, size: 20),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          goal.length > 50 ? '${goal.substring(0, 50)}...' : goal,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (hasTaskScreenshot) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.image,
                          size: 16,
                          color: Colors.blueGrey,
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    '$status · $steps steps · ${tokens}tokens',
                    style: TextStyle(fontSize: 11, color: statusColor),
                  ),
                  children: [
                    if (detailedSteps.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('No detailed step data available.',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                      )
                    else
                      ...detailedSteps.map((step) {
                        final s = step as Map<String, dynamic>;
                        final action = s['action'] ?? '?';
                        final reasoning = s['reasoning'] ?? '';
                        final result = s['result'] ?? '';
                        final success = s['success'] == true;
                        final hasScreenshot = s['screenshot'] != null;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            success ? Icons.check_circle_outline : Icons.error_outline,
                            color: success ? Colors.green : Colors.red,
                            size: 16,
                          ),
                          title: Text(
                            'Step ${s['step']}: $action',
                            style: const TextStyle(fontSize: 12),
                          ),
                          subtitle: Text(
                            reasoning.toString().isNotEmpty ? reasoning.toString() : result.toString(),
                            style: TextStyle(
                              fontSize: 11,
                              color: success ? null : Colors.red.shade300,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: hasScreenshot
                              ? const Icon(
                                  Icons.image,
                                  size: 18,
                                  color: Colors.blueGrey,
                                )
                              : null,
                        );
                      }),
                    const SizedBox(height: 8),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Returns a per-1K-token cost in USD based on the current base URL.
  /// DeepSeek → $0.001/1K; NVIDIA → $0.002/1K; default → DeepSeek pricing.
  double _costPer1kTokens() {
    final baseUrl = _baseUrlController.text.trim();
    if (AiService.isNvidiaBaseUrl(baseUrl)) {
      return 0.002;
    }
    return 0.001;
  }

  String _providerLabel() {
    final baseUrl = _baseUrlController.text.trim();
    return AiService.isNvidiaBaseUrl(baseUrl) ? 'NVIDIA' : 'DeepSeek';
  }

  /// Builds the analytics stats section shown inside the Execution logs card.
  Widget _buildAnalyticsStats(bool isDark) {
    final analytics = _taskAnalytics;
    final totalTasks = (analytics?['totalTasks'] ?? 0) as int;
    final successRate = (analytics?['successRate'] ?? 0.0) as double;
    final successCount = (analytics?['successCount'] ?? 0) as int;
    final failedCount = (analytics?['failedCount'] ?? 0) as int;
    final totalTokens = (analytics?['totalTokens'] ?? 0) as int;
    final costPer1k = _costPer1kTokens();
    final estimatedCost = (totalTokens / 1000.0) * costPer1k;

    String formatTokens(int tokens) {
      if (tokens >= 1000000) {
        return '${(tokens / 1000000).toStringAsFixed(2)}M';
      } else if (tokens >= 1000) {
        return '${(tokens / 1000).toStringAsFixed(1)}K';
      }
      return tokens.toString();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.analytics_outlined, size: 16),
            const SizedBox(width: 6),
            Text(
              'Usage Analytics',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
              ),
            ),
            const Spacer(),
            if (analytics == null)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              InkWell(
                onTap: _refreshAnalytics,
                borderRadius: BorderRadius.circular(12),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.refresh, size: 16),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _statTile(
                label: 'Total Tasks',
                value: '$totalTasks',
                icon: Icons.task_alt,
                color: Theme.of(context).primaryColor,
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _statTile(
                label: 'Success Rate',
                value: totalTasks == 0
                    ? '—'
                    : '${(successRate * 100).toStringAsFixed(0)}%',
                icon: Icons.check_circle_outline,
                color: Colors.green,
                isDark: isDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _statTile(
                label: 'Tokens Spent',
                value: formatTokens(totalTokens),
                icon: Icons.memory,
                color: Colors.deepPurple,
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _statTile(
                label: 'Est. Cost (${_providerLabel()})',
                value: '\$${estimatedCost.toStringAsFixed(3)}',
                icon: Icons.attach_money_rounded,
                color: Colors.amber.shade800,
                isDark: isDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (totalTasks > 0)
          Text(
            '$successCount succeeded · $failedCount failed · '
            '@ \$${costPer1k.toStringAsFixed(4)}/1K tokens',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
            ),
          ),
        if (totalTasks == 0 && analytics != null)
          Text(
            'Run a task to start collecting analytics.',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
            ),
          ),
      ],
    );
  }

  /// Small boxed stat tile used in the analytics section.
  Widget _statTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: color.withOpacity(0.25),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the children for the Scheduled Tasks card.
  List<Widget> _buildScheduledTasksChildren(bool isDark) {
    final children = <Widget>[];

    if (_scheduledTasks.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.inbox_outlined,
                size: 18,
                color: isDark
                    ? const Color(0xFF64748B)
                    : const Color(0xFF94A3B8),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No scheduled tasks yet. Add one below to run a goal '
                  'automatically on a recurring schedule.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF475569),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      for (var i = 0; i < _scheduledTasks.length; i++) {
        final task = _scheduledTasks[i];
        children.add(_buildScheduledTaskTile(task, i, isDark));
        if (i < _scheduledTasks.length - 1) {
          children.add(const Divider(height: 1));
        }
      }
    }

    children.add(const SizedBox(height: 12));
    children.add(
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => _showAddScheduledTaskDialog(isDark),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add Task'),
        ),
      ),
    );
    children.add(
      const SizedBox(height: 4),
    );
    children.add(
      Text(
        'Note: This stores schedules locally. Execution will be wired up to '
        'Android WorkManager in a future build.',
        style: TextStyle(
          fontSize: 10,
          color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
        ),
      ),
    );

    return children;
  }

  /// A single scheduled task tile with toggle + remove.
  Widget _buildScheduledTaskTile(
    Map<String, dynamic> task,
    int index,
    bool isDark,
  ) {
    final goal = task['goal']?.toString() ?? '(no goal)';
    final schedule = task['schedule']?.toString() ?? '';
    final enabled = task['enabled'] == true;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 2),
      leading: Icon(
        enabled ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 20,
        color: enabled ? Theme.of(context).primaryColor : Colors.grey,
      ),
      title: Text(
        goal,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          children: [
            Icon(
              Icons.timer_outlined,
              size: 12,
              color: isDark
                  ? const Color(0xFF94A3B8)
                  : const Color(0xFF64748B),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                schedule,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: enabled,
            onChanged: (val) {
              setState(() {
                _scheduledTasks[index]['enabled'] = val;
              });
              _saveScheduledTasks();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            color: Colors.red.shade400,
            tooltip: 'Remove',
            onPressed: () => _removeScheduledTask(index),
          ),
        ],
      ),
    );
  }

  /// Deletes a scheduled task after confirmation.
  void _removeScheduledTask(int index) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Task?'),
        content: const Text(
          'This scheduled task will be permanently removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              setState(() {
                _scheduledTasks.removeAt(index);
              });
              _saveScheduledTasks();
              Navigator.pop(ctx);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  /// Schedule-type options for the Add Task dialog.
  static const List<String> _schedulePresets = [
    'Every 30 min',
    'Every hour',
    'Daily at 9AM',
    'Custom cron',
  ];

  /// Maps a preset label to its cron expression.
  String _presetToCron(String preset) {
    switch (preset) {
      case 'Every 30 min':
        return '*/30 * * * *';
      case 'Every hour':
        return '0 * * * *';
      case 'Daily at 9AM':
        return '0 9 * * *';
      case 'Custom cron':
        return '';
      default:
        return '';
    }
  }

  /// Shows the Add Scheduled Task dialog.
  void _showAddScheduledTaskDialog(bool isDark) {
    final goalController = TextEditingController();
    String selectedPreset = _schedulePresets.first;
    final cronController = TextEditingController(text: _presetToCron(selectedPreset));
    bool enabled = true;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final showCronField = selectedPreset == 'Custom cron';
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.add_task_rounded, size: 24),
                  SizedBox(width: 8),
                  Text('Add Scheduled Task'),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: goalController,
                      maxLines: 2,
                      autofocus: true,
                      decoration: _buildInputDecoration(
                        labelText: 'Goal',
                        hintText: 'e.g. Check weather and send summary',
                        prefixIcon:
                            const Icon(Icons.flag_outlined, size: 18),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedPreset,
                      decoration: _buildInputDecoration(
                        labelText: 'Schedule',
                        hintText: 'Pick a frequency',
                        prefixIcon:
                            const Icon(Icons.timer_outlined, size: 18),
                      ),
                      items: _schedulePresets
                          .map((p) => DropdownMenuItem(
                                value: p,
                                child: Text(p, style: const TextStyle(fontSize: 13)),
                              ))
                          .toList(),
                      onChanged: (val) {
                        if (val == null) return;
                        setDialogState(() {
                          selectedPreset = val;
                          if (val != 'Custom cron') {
                            cronController.text = _presetToCron(val);
                          } else {
                            cronController.clear();
                          }
                        });
                      },
                    ),
                    if (showCronField) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: cronController,
                        decoration: _buildInputDecoration(
                          labelText: 'Cron Expression',
                          hintText: '*/30 * * * *',
                          prefixIcon: const Icon(Icons.code_rounded, size: 18),
                        ),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Format: min hour day-of-month month day-of-week',
                        style: TextStyle(
                          fontSize: 10,
                          color: isDark
                              ? const Color(0xFF64748B)
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: const Text('Enabled'),
                      subtitle: const Text(
                        'When off, the task is stored but not executed',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: enabled,
                      onChanged: (val) =>
                          setDialogState(() => enabled = val),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final goal = goalController.text.trim();
                    var schedule = cronController.text.trim();
                    if (selectedPreset != 'Custom cron') {
                      schedule = _presetToCron(selectedPreset);
                    }
                    if (goal.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please enter a goal.'),
                        ),
                      );
                      return;
                    }
                    if (schedule.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Please provide a valid schedule / cron expression.'),
                        ),
                      );
                      return;
                    }
                    final newTask = <String, dynamic>{
                      'id':
                          'task_${DateTime.now().millisecondsSinceEpoch}',
                      'goal': goal,
                      'schedule': schedule,
                      'enabled': enabled,
                    };
                    setState(() {
                      _scheduledTasks.add(newTask);
                    });
                    _saveScheduledTasks();
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Scheduled task added.'),
                      ),
                    );
                  },
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<Widget> _buildPermissionTiles() {
    final permissionMap = {
      'Microphone': Permission.microphone,
      'Contacts': Permission.contacts,
      'Phone': Permission.phone,
      'SMS': Permission.sms,
      'Notifications': Permission.notification,
    };

    final icons = {
      'Microphone': Icons.mic,
      'Contacts': Icons.contacts,
      'Phone': Icons.phone,
      'SMS': Icons.sms,
      'Notifications': Icons.notifications,
    };

    final list = permissionMap.entries.map((entry) {
      final status = _permissions[entry.key];
      final isGranted = status?.isGranted ?? false;

      return ListTile(
        leading: Icon(icons[entry.key]),
        title: Text(entry.key),
        trailing: isGranted
            ? Icon(
                Icons.check_circle,
                color: Theme.of(context).colorScheme.primary,
              )
            : TextButton(
                onPressed: () => _requestPermission(entry.key, entry.value),
                child: const Text('Grant'),
              ),
        subtitle: Text(
          isGranted
              ? 'Granted'
              : (status?.isDenied ?? true
                    ? 'Not granted'
                    : 'Denied permanently'),
          style: TextStyle(
            color: isGranted
                ? Theme.of(context).colorScheme.primary
                : Colors.orange,
            fontSize: 12,
          ),
        ),
      );
    }).toList();

    if (FeatureFlags.floatingOverlayEnabled) {
      list.add(
        ListTile(
          leading: const Icon(Icons.layers),
          title: const Text('Display Over Other Apps (Floating Bubble)'),
          trailing: _isOverlayPermissionGranted
              ? Icon(
                  Icons.check_circle,
                  color: Theme.of(context).colorScheme.primary,
                )
              : TextButton(
                  onPressed: () async {
                    await FlutterOverlayWindow.requestPermission();
                    final granted =
                        await FlutterOverlayWindow.isPermissionGranted();
                    setState(() {
                      _isOverlayPermissionGranted = granted;
                    });
                  },
                  child: const Text('Grant'),
                ),
          subtitle: Text(
            _isOverlayPermissionGranted ? 'Granted' : 'Not granted',
            style: TextStyle(
              color: _isOverlayPermissionGranted
                  ? Theme.of(context).colorScheme.primary
                  : Colors.orange,
              fontSize: 12,
            ),
          ),
        ),
      );
    }

    return list;
  }

  Widget _buildShizukuCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  widget.shizukuService.isAvailable
                      ? Icons.link
                      : Icons.link_off,
                  color: widget.shizukuService.isAvailable
                      ? Colors.green
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  widget.shizukuService.isAvailable
                      ? 'Shizuku is running'
                      : 'Shizuku not detected',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: widget.shizukuService.isAvailable
                        ? Colors.green
                        : Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!widget.shizukuService.isAvailable) ...[
              const Text(
                '1. Install Shizuku from Play Store\n'
                '2. Open Shizuku and start it via Wireless Debugging\n'
                '3. Come back here and tap "Check Again"',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  await widget.shizukuService.checkAvailability();
                  if (mounted) setState(() {});
                },
                child: const Text('Check Again'),
              ),
            ] else if (!widget.shizukuService.hasPermission) ...[
              OutlinedButton(
                onPressed: () async {
                  await widget.shizukuService.requestPermission();
                  if (mounted) setState(() {});
                },
                child: const Text('Grant Shizuku Permission'),
              ),
            ] else ...[
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    'Permission granted — ADB commands available',
                    style: TextStyle(color: Colors.green[700], fontSize: 13),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAccessibilityCard() {
    return FutureBuilder<bool>(
      future: widget.screenAutomationService.isServiceRunning(),
      builder: (context, snapshot) {
        final isRunning = snapshot.data ?? false;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isRunning ? Icons.visibility : Icons.visibility_off,
                      color: isRunning ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isRunning
                          ? 'Screen Control is active'
                          : 'Screen Control is disabled',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isRunning ? Colors.green : Colors.grey,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (!isRunning) ...[
                  const Text(
                    'Tap below to open Accessibility Settings, then find "Apex Agent Screen Control" and enable it.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await widget.screenAutomationService
                          .openAccessibilitySettings();
                    },
                    icon: const Icon(Icons.settings),
                    label: const Text('Open Accessibility Settings'),
                  ),
                ] else ...[
                  Text(
                    'Can read screen, tap, scroll, and type in other apps',
                    style: TextStyle(color: Colors.green[700], fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
