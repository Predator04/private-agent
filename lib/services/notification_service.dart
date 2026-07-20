import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool? _notificationsAllowed;
  int _nextNotificationId = 1000;

  // Dedicated ID for the ongoing task notification so we can cancel it
  static const int _taskProgressNotificationId = 999;

  Future<void> init() async {
    if (_initialized) return;

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await _notificationsPlugin.initialize(initializationSettings);
    _initialized = true;
  }

  Future<bool> requestPermission() async {
    if (!_initialized) await init();
    if (_notificationsAllowed != null) return _notificationsAllowed!;

    final android = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await android?.requestNotificationsPermission();
    _notificationsAllowed = granted ?? true;
    return _notificationsAllowed!;
  }

  /// Show a persistent ongoing notification while a task is running
  Future<void> showTaskProgress(int step, int maxSteps, String description) async {
    if (!_initialized) await init();
    if (!await requestPermission()) return;

    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
          'task_progress_channel',
          'Task Progress',
          channelDescription: 'Shows current task execution progress',
          importance: Importance.low,
          priority: Priority.defaultPriority,
          playSound: false,
          enableVibration: false,
          ongoing: true,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: maxSteps,
          progress: step,
          category: AndroidNotificationCategory.service,
          styleInformation: BigTextStyleInformation(description),
        );

    final NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await _notificationsPlugin.show(
      _taskProgressNotificationId,
      'Apex Agent — Step $step of $maxSteps',
      description,
      platformChannelSpecifics,
    );
  }

  /// Remove the persistent progress notification
  Future<void> cancelTaskProgress() async {
    await _notificationsPlugin.cancel(_taskProgressNotificationId);
  }

  Future<void> showTaskCompleteNotification(String title, String body) async {
    if (!_initialized) await init();
    if (!await requestPermission()) return;

    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
          'task_completion_channel',
          'Task Completions',
          channelDescription: 'Notifications for when a task completes',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.status,
          styleInformation: BigTextStyleInformation(body),
        );

    final NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await _notificationsPlugin.show(
      _nextNotificationId++,
      title,
      body,
      platformChannelSpecifics,
    );
  }
}
