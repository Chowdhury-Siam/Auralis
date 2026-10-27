import 'package:flutter/services.dart';

class SetupPermissions {
  const SetupPermissions();
  static const channel = MethodChannel('app.auralis/platform');
  Future<({bool notifications, bool battery})> status() async {
    final state = await channel.invokeMapMethod<String, dynamic>('setupStatus');
    return (
      notifications: state?['notifications'] == true,
      battery: state?['battery'] == true,
    );
  }

  Future<void> notifications() =>
      channel.invokeMethod<void>('setupNotifications');
  Future<void> battery() => channel.invokeMethod<void>('setupBattery');
}
