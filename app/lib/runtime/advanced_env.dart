// 高级权限环境（iOS）：巨魔、有根 / 无根 / 隐根越狱，以及能不能写系统目录。
//
// 数据来自原生通道 `dshgo/advanced_env` 的 detect 方法（原生侧
// DshPlugin.swift 的 AdvancedEnvironmentChannel 实现）。通道没注册时
// Flutter 抛 MissingPluginException —— 那等于「这台设备没有这个能力」，
// 这里按 null 降级，不把异常抛给界面。
import 'package:flutter/services.dart';

/// 原生侧一次探测的结果快照。
class AdvancedEnvironment {
  const AdvancedEnvironment({
    this.trollStore = false,
    this.rootful = false,
    this.rootless = false,
    this.roothide = false,
    this.shellPath,
    this.systemWritable = false,
    this.summaryLines = const <String>[],
  });

  /// 原生字典 → 快照。`shellPath` 可能是 NSNull，非 String 一律当没有。
  factory AdvancedEnvironment.fromMap(Map<Object?, Object?> raw) {
    final lines = raw['summaryLines'];
    return AdvancedEnvironment(
      trollStore: raw['trollStore'] == true,
      rootful: raw['rootful'] == true,
      rootless: raw['rootless'] == true,
      roothide: raw['roothide'] == true,
      shellPath: switch (raw['shellPath']) {
        final String path when path.isNotEmpty => path,
        _ => null,
      },
      systemWritable: raw['systemWritable'] == true,
      summaryLines: lines is List ? lines.whereType<String>().toList(growable: false) : const <String>[],
    );
  }

  /// 巨魔（TrollStore）。
  final bool trollStore;

  /// 有根越狱（rootful）：/usr/bin、/bin/bash 这类直接铺在根文件系统上。
  final bool rootful;

  /// 无根越狱（rootless）：/var/jb。
  final bool rootless;

  /// 隐根越狱（roothide）：.jbroot-* 目录加上 JBROOT 环境变量。
  final bool roothide;

  /// 能用的 shell 绝对路径；没有就是 null。
  final String? shellPath;

  /// 系统目录（/private/var/mobile）能不能写。
  final bool systemWritable;

  /// 原生排好序、可直接显示的文案。一个环境都没命中时是那句「未高级权限」。
  final List<String> summaryLines;

  /// 四类环境里是否至少命中一个。
  bool get anyDetected => trollStore || rootful || rootless || roothide;
}

/// [AdvancedEnvironment] 的通道客户端。测试里换成假通道。
class AdvancedEnvironmentChannel {
  const AdvancedEnvironmentChannel([this._methods = const MethodChannel('dshgo/advanced_env')]);

  final MethodChannel _methods;

  /// 探测一次。[force] 先让原生丢掉进程内缓存（原生没实现这个方法就算了，
  /// 接着照常 detect）。
  ///
  /// 没有原生实现、或原生报错时返回 null：设置页据此显示降级文案。
  Future<AdvancedEnvironment?> detect({bool force = false}) async {
    if (force) {
      try {
        final raw = await _methods.invokeMethod<Map>('invalidateCache');
        if (raw != null) return AdvancedEnvironment.fromMap(raw);
      } on MissingPluginException {
        // 原生侧只有 detect：下面再走一次。
      } on PlatformException {
        // 同上，重算失败就当没缓存。
      }
    }
    try {
      final raw = await _methods.invokeMethod<Map>('detect');
      return raw == null ? null : AdvancedEnvironment.fromMap(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
