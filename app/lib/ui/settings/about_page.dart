// About DSH Go: app information, the original author and personal profiles,
// then the brand mark, slogan and unofficial-app disclaimer.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../../state/star_prompt.dart' show starLinkOpenerProvider;
import '../../state/update_state.dart';
import '../shell/brand_mark.dart';
import '../shell/page_frame.dart';
import '../star/star_prompt_dialog.dart' show openStarProject;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../update/update_tiles.dart';
import 'settings_widgets.dart';

/// The installed version as the app shows it: `0.9.6 (10271234)`.
String installedVersionLabel(WidgetRef ref) {
  // What Android reports as installed (the compiled-in constant until it does).
  final installed = ref.watch(appUpdateProvider.select((s) => s.current));
  return installed.build == null ? installed.name : '${installed.name} (${installed.build})';
}

/// 交流群：QQ 群的分享页。没装 QQ 时浏览器也能打开，所以照常交给系统。
const qqGroupUrl =
    'https://qun.qq.com/universal-share/share?ac=1&authKey=oaXaDZhiv%2FsRSavAEgZccqbE3jCYiR6mxZmSOboVlfiz7h9QkUCqtEV2v8zgZpUB&busi_data=eyJncm91cENvZGUiOiIxNzE0NjE1MDUiLCJ0b2tlbiI6ImxFV1ViNUQ2ZUp5T2RoSUtPVUp3ZVdxaHFDWmtseXRVbmhHK0xRZ2U2TUduclJwWDlFRVJZZHBEV1F1eDlyOXgiLCJ1aW4iOiIzODY3NjMxOTUifQ%3D%3D&data=cwtP871gkZLxbHM7-RMwkC56OHLLMij5SYyOdE4xaGAxvTASBi9VZKGu3rLF4t4ShM3Uu1AMW_I2597XQmM_6w&svctype=4&tempid=h5_group_info';

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final version = installedVersionLabel(ref);
    return AppPage.list(
      title: l10n.hubAbout,
      children: [
        SettingsSection(
          children: [
            SettingsTile(
              spot: Spots.version,
              value: Text(version, style: AppType.tabular(theme.textTheme.bodyMedium!)),
            ),
            const AppUpdateTiles(),
            SettingsTile(
              key: const ValueKey('settings-star'),
              spot: Spots.star,
              onTap: () => unawaited(
                openStarProject(ProviderScope.containerOf(context, listen: false), ScaffoldMessenger.maybeOf(context)),
              ),
            ),
            SettingsTile(
              spot: Spots.licenses,
              onTap: () => showLicensePage(
                context: context,
                applicationName: AppInfo.name,
                applicationVersion: version,
                applicationIcon: const Padding(padding: EdgeInsets.all(12), child: BrandMark(size: 56, tile: true)),
                applicationLegalese: AppInfo.disclaimer,
              ),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubAboutAuthor,
          children: [
            const SettingsTile(title: AppInfo.author),
            _authorLink(
              context,
              ref,
              'about-author-bilibili',
              l10n.hubAboutBilibili,
              AppInfo.authorBilibiliName,
              AppInfo.authorBilibiliUrl,
            ),
            _authorLink(context, ref, 'about-author-x', l10n.hubAboutX, AppInfo.authorXHandle, AppInfo.authorXUrl),
            _authorLink(
              context,
              ref,
              'about-author-github',
              l10n.hubAboutGithub,
              '@${AppInfo.author}',
              AppInfo.authorGithubUrl,
            ),
          ],
        ),
        // 高级功能的署名，和进群的入口。群链接是一个 https 分享页：
        // 装了 QQ 会拉起 QQ，没装就用浏览器打开；都不行就把地址复制走。
        SettingsSection(
          children: [
            SettingsTile(key: const ValueKey('about-contributor'), title: l10n.hubAboutContributor),
            SettingsTile(
              key: const ValueKey('about-qq-group'),
              title: l10n.hubAboutJoinGroup,
              subtitle: l10n.hubAboutJoinGroupHint,
              trailing: Icon(AppIcons.openExternal, size: 18, color: colors.textTertiary),
              onTap: () => unawaited(_openGroup(context, ref)),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Column(
            children: [
              BrandMark(size: 18, color: colors.textDisabled),
              const SizedBox(height: 10),
              Text(
                AppInfo.slogan,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
              ),
              const SizedBox(height: 8),
              Text(
                AppInfo.disclaimer,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _authorLink(BuildContext context, WidgetRef ref, String key, String title, String handle, String url) =>
      Semantics(
        link: true,
        child: SettingsTile(
          key: ValueKey(key),
          title: title,
          subtitle: handle,
          trailing: Icon(AppIcons.openExternal, size: 18, color: DshColors.of(context).textTertiary),
          onTap: () => unawaited(_openAuthorLink(context, ref, Uri.parse(url))),
        ),
      );

  /// 「加入交流群」：走 App 统一的链接口（url_launcher 的外部应用模式）。
  /// 打不开（没装 QQ、也没有浏览器）时把地址复制走并说一声，不让点击变成没反应。
  Future<void> _openGroup(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (await ref.read(starLinkOpenerProvider)(Uri.parse(qqGroupUrl))) return;
    } catch (_) {
      // url_launcher 抛异常也落到复制：一次点击总要有结果。
    }
    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: qqGroupUrl));
    } catch (_) {
      copied = false;
    }
    if (messenger?.mounted ?? false) {
      messenger!.showSnackBar(SnackBar(content: Text(copied ? l10n.hubAboutGroupCopied : l10n.hubAboutGroupOpenFailed)));
    }
  }

  Future<void> _openAuthorLink(BuildContext context, WidgetRef ref, Uri url) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (await ref.read(starLinkOpenerProvider)(url)) return;
    } catch (_) {
      // As with the project's link, fall back to copying when no browser opens.
    }
    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: url.toString()));
    } catch (_) {
      copied = false;
    }
    if (messenger?.mounted ?? false) {
      messenger!.showSnackBar(
        SnackBar(content: Text(copied ? l10n.shellBrowserUrlCopied : l10n.stateBrowserOpenFailed)),
      );
    }
  }
}
