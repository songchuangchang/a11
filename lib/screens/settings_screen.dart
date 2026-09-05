import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show kAppVersionConst;
import '../l10n/app_localizations.dart';
import '../providers/locale_provider.dart';
import '../services/app_update_service.dart';
import 'backup_settings_screen.dart';
import 'font_size_settings_screen.dart';
import 'general_settings_screen.dart';
import 'about_settings_screen.dart';
import 'logs_debug_settings_screen.dart';
import 'qa_settings_screen.dart';
import 'security_scan_settings_screen.dart';
import 'web_search_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // v1.6.9 build42 修复 F2：从全局常量引用（pubspec.yaml + constants.dart 单点更新后自动同步），不再写死避免遗漏
  static String get _appVersionFull => kAppVersionConst;

  // v1.7.12：APP 手动检查更新
  bool _checkingAppUpdate = false;
  bool _downloadingAppUpdate = false;

  // v1.7.15 第二轮拆分：原日志/自检/通用三组 Section + 相关状态字段 + 异步方法
  // 全部已分别迁到：
  //   - logs_debug_settings_screen.dart（详细日志开关 + 日志查看/导出/清空）
  //   - qa_settings_screen.dart（自检 + AI 行为测试开关）
  //   - general_settings_screen.dart（关于/API配置/存储/支持的服务商）
  // 主 settings 只剩版本检查更新按钮、语言切换、和 7 个 sub-screen 的导航 ListTile，
  // 不含任何 Switch / SwitchListTile，从根上消除"白窗口"高度突变源。

  /// v1.7.12：APP 更新确认对话框（展示新版信息 + 下载 + 进度条）
  Future<void> _showAppUpdateDialog(
    AppUpdateInfo info,
    bool zh,
    ColorScheme colorScheme,
  ) async {
    final sizeMb = (info.apkSize / 1024 / 1024).toStringAsFixed(2);
    int received = 0;
    int total = info.apkSize;
    await showDialog<void>(
      context: context,
      barrierDismissible: !_downloadingAppUpdate, // 下载中不允许误点关闭
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(children: [
            Icon(Icons.system_update_rounded, color: colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(zh
                  ? '发现新版本 v${info.latestVersion}'
                  : 'New version v${info.latestVersion} available'),
            ),
          ]),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          zh
                              ? '当前版本：v${info.currentVersion}'
                              : 'Current: v${info.currentVersion}',
                          style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Text(
                          zh
                              ? '最新版本：v${info.latestVersion}'
                              : 'Latest:  v${info.latestVersion}',
                          style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.primary,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(
                          zh
                              ? '安装包大小：${sizeMb}MB'
                              : 'APK size: ${sizeMb}MB',
                          style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant)),
                      if (info.publishedAt != null) ...[
                        const SizedBox(height: 2),
                        Text(
                            zh
                                ? '发布时间：${info.publishedAt!.substring(0, info.publishedAt!.length > 10 ? 10 : info.publishedAt!.length)}'
                                : 'Released: ${info.publishedAt!.substring(0, info.publishedAt!.length > 10 ? 10 : info.publishedAt!.length)}',
                            style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(zh ? '更新说明：' : 'Release notes:',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      info.releaseNotes.isEmpty
                          ? (zh ? '(无)' : '(none)')
                          : info.releaseNotes,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                if (_downloadingAppUpdate) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: total > 0
                              ? received.clamp(0, total) / total
                              : null,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                          total > 0
                              ? '${(received / 1024).toStringAsFixed(0)}/${(total / 1024).toStringAsFixed(0)} KB'
                              : (zh ? '下载中…' : 'Downloading…'),
                          style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: _downloadingAppUpdate
              ? [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(zh ? '后台继续下载' : 'Keep downloading'),
                  ),
                ]
              : [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(zh ? '稍后' : 'Later'),
                  ),
                  FilledButton.icon(
                    onPressed: () async {
                      setDialogState(() {
                        _downloadingAppUpdate = true;
                        received = 0;
                      });
                      final res = await AppUpdateService.downloadAndInstall(
                        info,
                        onProgress: (r, t) {
                          if (ctx.mounted) {
                            setDialogState(() {
                              received = r;
                              if (t > 0) total = t;
                            });
                          }
                        },
                      );
                      if (ctx.mounted) {
                        setDialogState(() => _downloadingAppUpdate = false);
                        final ok = res['success'] == true;
                        final path = res['fullPath'] as String? ?? '';
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(
                            content: Text(ok
                                ? (zh
                                    ? '✅ 下载完成：$path\n如未自动弹出安装器，请手动点击安装'
                                    : '✅ Downloaded: $path\nIf installer did not open, tap the file manually')
                                : (zh
                                    ? '❌ 下载失败：${res['error']}'
                                    : '❌ Download failed: ${res['error']}')),
                            duration: const Duration(seconds: 6),
                            backgroundColor:
                                ok ? Theme.of(ctx).colorScheme.primary : Theme.of(ctx).colorScheme.error,
                          ),
                        );
                        Navigator.pop(ctx);
                      }
                    },
                    icon: const Icon(Icons.download_for_offline_outlined),
                    label: Text(zh ? '下载并安装' : 'Download & Install'),
                  ),
                ],
        ),
      ),
    );
  }

  /// v1.6.5：设置页语言切换弹窗（跟随系统 / 简体中文 / English）
  /// 选中即生效并落盘 SharedPreferences，重启后由 main.dart 的
  /// 全局 LocaleProvider.init() 恢复（修复：选英文后重启回落中文）。
  Future<void> _showLanguagePicker() async {
    final l = AppLocalizations.of(context);
    final current = context.read<LocaleProvider>().locale?.languageCode;
    await showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l.tr('language')),
        children: [
          _languageOption(ctx, null, l.tr('systemLanguage'), current),
          _languageOption(ctx, 'zh', '简体中文', current),
          _languageOption(ctx, 'en', 'English', current),
        ],
      ),
    );
  }

  Widget _languageOption(
      BuildContext ctx, String? code, String label, String? current) {
    final selected = code == current;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(label),
      onTap: () async {
        final lp = ctx.read<LocaleProvider>();
        if (code == null) {
          await lp.setSystemLocale();
        } else {
          await lp.setLocale(Locale(code));
        }
        if (ctx.mounted) Navigator.pop(ctx);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    // v1.6.5：watch 保证设置页语言切换后（locale 变化）本页立即重建
    final lp = context.watch<LocaleProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(l.tr('settings'))),
      body: ListView(
        children: [
          // ===== 版本号 + 检查更新按钮 =====
          Container(
            margin: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.35)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.new_releases_outlined,
                        color: colorScheme.onPrimaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Nexus',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15)),
                          Text(
                            'Version $_appVersionFull',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: colorScheme.onPrimaryContainer,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _checkingAppUpdate
                          ? null
                          : () async {
                              setState(() => _checkingAppUpdate = true);
                              final info = await AppUpdateService.checkForUpdate();
                              if (!mounted) return;
                              setState(() {
                                _checkingAppUpdate = false;
                              });
                              final zhIs = l.locale.languageCode == 'zh';
                              if (!info.hasUpdate) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(zhIs
                                          ? '🎉 当前已是最新版本 v${info.currentVersion}'
                                          : '🎉 Already on the latest version v${info.currentVersion}'),
                                      backgroundColor: colorScheme.primary,
                                    ),
                                  );
                                }
                                return;
                              }
                              // 有更新：弹确认对话框
                              await _showAppUpdateDialog(info, zhIs, colorScheme);
                            },
                      icon: _checkingAppUpdate
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colorScheme.onPrimaryContainer))
                          : const Icon(Icons.system_update_alt_outlined, size: 18),
                      label: Text(zh ? '检查更新' : 'Check Update',
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(indent: 16, endIndent: 16),

          // ===== v1.6.5：语言切换（跟随系统 / 简体中文 / English） =====
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l.tr('language')),
            subtitle: Text(lp.locale == null
                ? l.tr('systemLanguage')
                : (lp.locale!.languageCode == 'zh' ? '简体中文' : 'English')),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showLanguagePicker,
          ),
          const Divider(indent: 16, endIndent: 16),

          // ===== v1.7.15：7 个 sub-screen 导航入口（数据驱动，消除手写三元/重复）=====
          for (final section in _kSubScreens) ...[
            ListTile(
              dense: true,
              leading: Icon(section.icon),
              title: Text(section.title(zh, l)),
              subtitle: Text(
                section.subtitle(zh),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => section.builder()),
              ),
            ),
            const Divider(),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SettingsSection {
  final IconData icon;
  final String Function(bool zh, AppLocalizations l) title;
  final String Function(bool zh) subtitle;
  final Widget Function() builder;

  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });
}

final _kSubScreens = <_SettingsSection>[
  _SettingsSection(
    icon: Icons.travel_explore_outlined,
    title: (zh, l) => l.tr('webSearch'),
    subtitle: (zh) => zh ? '联网搜索引擎与 API Key 配置' : 'Web search engines & API key config',
    builder: () => const WebSearchSettingsScreen(),
  ),
  _SettingsSection(
    icon: Icons.security_outlined,
    title: (zh, l) => l.tr('securityScan'),
    subtitle: (zh) => zh
        ? '本地规则扫描（默认开启）+ 可选 SkillSpector/MobSF 深度审查'
        : 'Local rule scan (on by default) + optional SkillSpector/MobSF deep scan',
    builder: () => const SecurityScanSettingsScreen(),
  ),
  _SettingsSection(
    icon: Icons.backup_outlined,
    title: (zh, _) => zh ? '数据备份' : 'Data Backup',
    subtitle: (zh) => zh
        ? '导出/导入所有对话、API 配置、搜索设置'
        : 'Export/import all conversations, API configs and settings',
    builder: () => const BackupSettingsScreen(),
  ),
  _SettingsSection(
    icon: Icons.tune_outlined,
    title: (zh, _) => zh ? '通用设置' : 'General',
    subtitle: (zh) => zh
        ? '生物识别 / 云端更新 / 代理'
        : 'Biometric / Remote update / Proxy',
    builder: () => const GeneralSettingsScreen(),
  ),
  _SettingsSection(
    icon: Icons.text_fields,
    title: (zh, _) => zh ? '字体设置' : 'Font Settings',
    subtitle: (zh) => zh
        ? '聊天文字大小与预览（独立页，不挤压通用设置）'
        : 'Chat text size & preview (separate page)',
    builder: () => const FontSizeSettingsScreen(),
  ),
  _SettingsSection(
    icon: Icons.info_outline,
    title: (zh, _) => zh ? '关于' : 'About',
    subtitle: (zh) => zh
        ? '关于本应用 / API 配置 / 存储 / 支持的服务商'
        : 'About / API configs / Storage / Supported providers',
    builder: () => const AboutSettingsScreen(),
  ),
  _SettingsSection(
    icon: Icons.article_outlined,
    title: (zh, _) => zh ? '日志与调试' : 'Logs & Debug',
    subtitle: (zh) => zh
        ? '查看/导出日志，开启详细调试模式'
        : 'View/export logs and enable verbose debug mode',
    builder: () => const LogsDebugSettingsScreen(),
  ),
  _SettingsSection(
    icon: Icons.fact_check_outlined,
    title: (zh, _) => zh ? '自检与 QA 工具' : 'Self-check & QA Tools',
    subtitle: (zh) => zh
        ? '运行一键自检或 AI 行为回归测试'
        : 'Run self-check or AI behavior regression tests',
    builder: () => const QaSettingsScreen(),
  ),
];
