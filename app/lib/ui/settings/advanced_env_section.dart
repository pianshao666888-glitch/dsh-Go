// 设置首屏的「高级权限环境」一块：这台 iPhone 上有没有巨魔 / 越狱，
// 以及能不能读写系统目录。
//
// 文案由原生通道 dshgo/advanced_env 的 summaryLines 直接给出（已排好序），
// Dart 侧只负责排版：一行一条，最后一行是「重新检测」。
// 通道缺失（MissingPluginException）时静默降级成那句「未高级权限」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/advanced_env_state.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'settings_widgets.dart';

/// 高级权限环境：探测到几类环境就几行，外加 shell 路径和刷新行。
class AdvancedEnvSection extends ConsumerWidget {
  const AdvancedEnvSection({super.key, this.tint = 5});

  /// 图标底色，和所在分组的 hue 一致（默认「通用」那一组）。
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final env = ref.watch(advancedEnvironmentProvider);
    final detected = env.value;
    // 原生一行都没给（或压根没有原生实现）时，显示降级的那句人话。
    final lines = detected?.summaryLines ?? const <String>[];
    final shown = lines.isEmpty ? <String>[l10n.advancedEnvUnsupported] : lines;
    final shell = detected?.shellPath;
    const spinner = SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2));
    return SettingsSection(
      title: l10n.advancedEnvTitle,
      footer: Text(l10n.advancedEnvFooter),
      children: [
        // 第一次还没回来：先给一行「正在检测…」，别先闪一句误导性的降级文案。
        if (detected == null)
          SettingsTile(
            key: const ValueKey('advanced-env-detecting'),
            icon: AppIcons.loading,
            tint: tint,
            tinted: false,
            title: l10n.advancedEnvDetecting,
            value: env.isLoading ? spinner : null,
          )
        else ...[
          for (final line in shown)
            SettingsTile(
              key: ValueKey('advanced-env-$line'),
              title: line,
            ),
          if (shell != null)
            SettingsTile(
              key: const ValueKey('advanced-env-shell'),
              icon: AppIcons.command,
              tint: tint,
              tinted: false,
              title: l10n.advancedEnvShell,
              value: Text(shell, style: AppType.tabular(theme.textTheme.bodyMedium!)),
            ),
        ],
        SettingsTile(
          key: const ValueKey('advanced-env-refresh'),
          icon: AppIcons.refresh,
          tint: tint,
          tinted: false,
          title: l10n.advancedEnvRefresh,
          chevron: false,
          value: env.isLoading ? spinner : null,
          onTap: env.isLoading ? null : () => ref.invalidate(advancedEnvironmentProvider),
        ),
      ],
    );
  }
}
