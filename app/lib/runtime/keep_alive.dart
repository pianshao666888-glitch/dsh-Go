// 后台保活（iOS）：用静音音频 / 持续定位把引擎在后台多撑一会儿。
//
// iOS 没有 Android 那种前台服务，App 进后台后系统会很快挂起进程。
// 能合法延缓的手段只有两类已声明的 background mode：
//   audio    —— 循环播放近静音音频，进程不会被立刻冻结（Info.plist 已含 audio）
//   location —— 持续定位，需要 UIBackgroundModes 追加 location 且授权「始终允许」
//
// 这不是常驻：内存压力大时系统仍会回收。要真常驻只能越狱用 launchd。
// 类名带 Background 前缀：Flutter 的 sliver.dart 已有同名 KeepAlive widget。
import 'package:flutter/services.dart';

/// 一侧开关的状态快照。
class KeepAliveStatus {
  const KeepAliveStatus({
    this.audio = false,
    this.location = false,
    this.locationAuthorization = 'unknown',
  });

  factory KeepAliveStatus.fromMap(Map<Object?, Object?> raw) => KeepAliveStatus(
        audio: raw['audio'] == true,
        location: raw['location'] == true,
        locationAuthorization: (raw['locationAuthorization'] as String?) ?? 'unknown',
      );

  final bool audio;
  final bool location;

  /// notDetermined / whenInUse / always / denied / restricted
  final String locationAuthorization;

  bool get locationNeedsAlways =>
      locationAuthorization == 'whenInUse' || locationAuthorization == 'notDetermined';

  KeepAliveStatus copyWith({bool? audio, bool? location, String? locationAuthorization}) =>
      KeepAliveStatus(
        audio: audio ?? this.audio,
        location: location ?? this.location,
        locationAuthorization: locationAuthorization ?? this.locationAuthorization,
      );
}

class BackgroundKeepAlive {
  const BackgroundKeepAlive();

  static const _channel = MethodChannel('dshgo/keepalive');

  /// 当前状态。没有原生实现（Android/鸿蒙/桌面）时返回全关，不报错。
  Future<KeepAliveStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<Map>('status');
      return KeepAliveStatus.fromMap(raw ?? const {});
    } on MissingPluginException {
      return const KeepAliveStatus();
    } on PlatformException {
      return const KeepAliveStatus();
    }
  }

  /// 静音音频通道。返回是否真的开启成功。
  Future<bool> setAudio(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('setAudio', {'on': on}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 定位通道。首次开启会弹权限请求；用户没给「始终允许」时返回 false。
  Future<bool> setLocation(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('setLocation', {'on': on}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
