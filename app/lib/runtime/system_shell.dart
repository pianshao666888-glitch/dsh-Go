// 系统终端：在越狱 / 巨魔环境下直接执行设备上的命令。
//
// 与 iSH guest 里那个 bash 不同——那个跑在 App 沙盒内的 Alpine 里，看不到
// iOS 自己的文件系统。这个走 App 原生的 posix_spawn，shell 取自真实系统路径
// （/var/jb/bin/sh 无根越狱、/bin/sh 有根越狱、巨魔下的 /usr/bin/sh 等）。
//
// 没有高级权限时所有方法返回 null / 空，不抛异常：调用方据此判断「不可用」而不是
// 「出错了」。越狱检测和 shell 探测都在原生侧做，这里只做通道封装。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 一次命令执行的结果。
class ShellResult {
  const ShellResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.timedOut = false,
    this.truncated = false,
  });

  factory ShellResult.fromMap(Map<Object?, Object?> raw) => ShellResult(
        exitCode: (raw['exitCode'] as num?)?.toInt() ?? -1,
        stdout: (raw['stdout'] as String?) ?? '',
        stderr: (raw['stderr'] as String?) ?? '',
        timedOut: raw['timedOut'] == true,
        truncated: raw['truncated'] == true,
      );

  final int exitCode;
  final String stdout;
  final String stderr;

  /// 超时被强杀。
  final bool timedOut;

  /// 输出超过上限被截断（head + tail 保留）。
  final bool truncated;

  bool get ok => exitCode == 0 && !timedOut;

  /// 给模型看的合并输出，和 bash 工具的口径一致。
  String get combined {
    final out = StringBuffer();
    if (stdout.isNotEmpty) out.write(stdout);
    if (stderr.isNotEmpty) {
      if (out.isNotEmpty && !stdout.endsWith('\n')) out.write('\n');
      out.write(stderr);
    }
    return out.toString();
  }
}

/// 原生终端通道。不可用时全部方法安全降级。
class SystemShell {
  const SystemShell();

  static const _channel = MethodChannel('dshgo/system_shell');

  /// 可用的 shell 绝对路径。没有高级权限时返回 null。
  Future<String?> shellPath() async {
    try {
      return await _channel.invokeMethod<String>('shellPath');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 是否具备执行系统命令的能力（越狱 / 巨魔）。
  Future<bool> available() async => (await shellPath()) != null;

  /// 执行一条命令。
  ///
  /// [command] 交给 shell 的 `-c`（所以管道、重定向、`&&` 都能用）。
  /// [timeoutMs] 超时后原生侧 SIGKILL 整棵进程树。
  /// 没有高级权限、或原生拒绝时返回 null——调用方要区分「没权限」和「命令失败」。
  Future<ShellResult?> exec(
    String command, {
    String? cwd,
    Map<String, String>? env,
    int timeoutMs = 30000,
    int maxBytes = 256 * 1024,
  }) async {
    if (command.trim().isEmpty) {
      return const ShellResult(exitCode: 0);
    }
    try {
      final raw = await _channel.invokeMethod<Map>('exec', {
        'command': command,
        'cwd': cwd,
        'env': env,
        'timeoutMs': timeoutMs,
        'maxBytes': maxBytes,
      });
      if (raw == null) return null;
      return ShellResult.fromMap(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 读一个文件（原始字节）。越狱环境下能读系统文件。
  Future<Uint8List?> readFile(String path, {int maxBytes = 4 * 1024 * 1024}) async {
    try {
      final raw = await _channel.invokeMethod<Uint8List>('readFile', {
        'path': path,
        'maxBytes': maxBytes,
      });
      return raw;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 读一个文件并当 UTF-8 文本返回。二进制内容会被替换成 U+FFFD。
  Future<String?> readText(String path, {int maxBytes = 1024 * 1024}) async {
    final bytes = await readFile(path, maxBytes: maxBytes);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 列目录。返回 null 表示不可用或读不到。
  Future<List<ShellEntry>?> list(String path) async {
    try {
      final raw = await _channel.invokeMethod<List>('list', {'path': path});
      if (raw == null) return null;
      return raw
          .whereType<Map>()
          .map((m) => ShellEntry.fromMap(m))
          .toList(growable: false);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 写一个文件。只有 systemWritable 为真时才会成功。
  Future<bool> writeFile(String path, List<int> bytes) async {
    try {
      return await _channel.invokeMethod<bool>('writeFile', {
            'path': path,
            'bytes': bytes,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// 目录条目。
class ShellEntry {
  const ShellEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.modified,
  });

  factory ShellEntry.fromMap(Map<Object?, Object?> raw) => ShellEntry(
        name: (raw['name'] as String?) ?? '',
        path: (raw['path'] as String?) ?? '',
        isDirectory: raw['isDirectory'] == true,
        size: (raw['size'] as num?)?.toInt() ?? 0,
        modified: (raw['modified'] as num?)?.toInt(),
      );

  final String name;
  final String path;
  final bool isDirectory;
  final int size;

  /// Unix 时间戳（秒）。
  final int? modified;
}
