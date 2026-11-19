// 设置 · 高级权限环境的数据源。
//
// 值来自原生通道 [AdvancedEnvironmentChannel]；null 表示没有原生实现
// （不是 iPhone，或者原生还没注册这个通道），界面按「未高级权限」降级。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/advanced_env.dart';

/// 探测通道。测试里覆盖成假实现，不碰真原生。
final advancedEnvironmentChannelProvider = Provider<AdvancedEnvironmentChannel>(
  (ref) => const AdvancedEnvironmentChannel(),
);

/// 这台设备的高级权限环境。
///
/// 进设置时才第一次读取（provider 是懒的），之后一直用同一份结果；
/// 点「重新检测」时界面 invalidate 它，重新跑一次并强制原生重算。
final advancedEnvironmentProvider = FutureProvider<AdvancedEnvironment?>(
  (ref) => ref.watch(advancedEnvironmentChannelProvider).detect(force: true),
);
