import 'package:flutter/services.dart';

/// Название часового пояса устройства (например, Europe/Moscow).
/// Значение отдаёт MainActivity.kt приложения, чужих плагинов не требуется.
class FlutterTimezone {
  static const MethodChannel _channel = MethodChannel('interlight/timezone');

  static Future<String> getLocalTimezone() async {
    final name = await _channel.invokeMethod<String>('getLocalTimezone');
    return name ?? 'UTC';
  }
}

