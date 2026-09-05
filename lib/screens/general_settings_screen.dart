// v1.7.15 第二轮拆分：原 settings_screen.dart 的"通用设置" Section +
// About / API Configs / Storage / Supported APIs 4 个 ListTile
//
// 目的：把通用设置从主 SettingsScreen 拆到独立 sub-screen，主 settings 只剩
// 导航 ListTile，行数从 1077 → <500。
//
// 设计权衡：本来这一 Section 没有高度突变 Switch，但拆出来后主 settings 变得
// 一目了然（只剩导航入口），且关于/存储这种"信息类" ListTile 单独成页更符合
// 用户预期。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/api_provider_template.dart';
import '../services/builtin_prompt_catalog.dart';
import '../models/web_search_config.dart';
import '../services/biometric_service.dart';
import '../services/storage_service.dart';

class GeneralSettingsScreen extends StatelessWidget {
  const GeneralSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '通用设置' : 'General')),
      // v1.7.25：设置页固定缩放，避免全局字体缩放挤压布局
      body: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Container(
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Row(
                    children: [
                      Icon(Icons.tune_outlined, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(zh ? '通用设置' : 'General',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15)),
                            const SizedBox(height: 2),
                            Text(
                              zh ? '生物识别 / 云端更新 / 代理'
                                 : 'Biometric / Remote update / Proxy',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // v1.7.25：信息类（关于/API配置/存储/服务商/GitHub）已拆到「关于」页
                _buildApiTemplateRemoteTile(context, zh),
                _buildPromptRemoteTile(context, zh),
                _buildGitHubProxyTile(context, zh),
                _buildBiometricLockTile(context, zh),

              ],
            ),
          ),
        ),
      ),
    );
  }

  /// v1.7.24 (#5/#6)：ReAct 协议云端更新入口（远程 JSON 覆盖内置 prompt，无需发版）
  Widget _buildPromptRemoteTile(BuildContext context, bool zh) {
    final cat = BuiltinPromptCatalog.instance;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.settings_input_antenna_outlined),
      title: Text(zh ? 'ReAct 协议云端更新' : 'ReAct Protocol Remote Update'),
      subtitle: Text(
        cat.hasRemote
            ? (zh ? '已载入远程协议 · ${cat.lastMessage}' : 'Remote loaded · ${cat.lastMessage}')
            : (zh ? '从远程 JSON 更新内置协议/触发词，无需发版' : 'Update built-in protocols from remote JSON, no release needed'),
        style: const TextStyle(fontSize: 12),
      ),
      onTap: () => _showPromptRemoteDialog(context, zh),
    );
  }

  void _showPromptRemoteDialog(BuildContext context, bool zh) {
    final cat = BuiltinPromptCatalog.instance;
    final controller = TextEditingController(
      // v1.7.30: 默认走 jsdelivr 镜像（raw.githubusercontent.com 在部分地区被墙）
      text: 'https://fastly.jsdelivr.net/gh/songchuangchang/a11@main/builtin_prompts.json',
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '更新 ReAct 协议' : 'Update ReAct Protocols'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: zh ? '远程 JSON 地址' : 'Remote JSON URL',
                hintText: 'https://.../builtin_prompts.json',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            Text(
              cat.lastMessage.isEmpty ? '' : cat.lastMessage,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await cat.refreshOnline(controller.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(cat.lastMessage)),
                );
              }
            },
            child: Text(zh ? '立即更新' : 'Update Now'),
          ),
        ],
      ),
    );
  }

  /// v1.7.24 (#7)：API 模板云端更新入口（远程 JSON → 覆盖/追加模板，无需发版）
  Widget _buildApiTemplateRemoteTile(BuildContext context, bool zh) {
    final cat = ApiProviderTemplateCatalog.instance;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.cloud_sync_outlined),
      title: Text(zh ? 'API 模板云端更新' : 'API Template Remote Update'),
      subtitle: Text(
        cat.hasRemote
            ? (zh ? '已载入远程模板 · ${cat.lastMessage}' : 'Remote loaded · ${cat.lastMessage}')
            : (zh ? '从远程 JSON 更新服务商模板，无需发版' : 'Update provider templates from remote JSON, no release needed'),
        style: const TextStyle(fontSize: 12),
      ),
      onTap: () => _showApiTemplateRemoteDialog(context, zh),
    );
  }

  void _showApiTemplateRemoteDialog(BuildContext context, bool zh) {
    final cat = ApiProviderTemplateCatalog.instance;
    final controller = TextEditingController(
      text: 'https://fastly.jsdelivr.net/gh/songchuangchang/a11@main/api_templates.json',
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '更新 API 模板' : 'Update API Templates'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: zh ? '远程 JSON 地址' : 'Remote JSON URL',
                hintText: 'https://.../api_templates.json',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            Text(
              cat.lastMessage.isEmpty ? '' : cat.lastMessage,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await cat.refreshOnline(controller.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(cat.lastMessage)),
                );
              }
            },
            child: Text(zh ? '立即更新' : 'Update Now'),
          ),
        ],
      ),
    );
  }

  Widget _buildGitHubProxyTile(BuildContext context, bool zh) {
    return FutureBuilder<WebSearchConfig>(
      future: context.read<StorageService>().getWebSearchConfig(),
      builder: (context, snapshot) {
        final proxy = snapshot.data?.githubProxyUrl ?? '';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.swap_horiz_outlined),
          title: Text(zh ? 'GitHub 代理' : 'GitHub Proxy'),
          subtitle: Text(
            proxy.isNotEmpty ? proxy : (zh ? '未设置（直连）' : 'Not set (direct)'),
            style: const TextStyle(fontSize: 12),
          ),
          onTap: proxy.isNotEmpty
              ? () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(zh ? 'GitHub 代理地址' : 'GitHub Proxy URL'),
                      content: Text(proxy),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(zh ? '关闭' : 'Close'),
                        ),
                      ],
                    ),
                  );
                }
              : null,
        );
      },
    );
  }

  Widget _buildBiometricLockTile(BuildContext context, bool zh) {
    final storage = context.read<StorageService>();
    return FutureBuilder<bool>(
      future: BiometricService.isAvailable,
      builder: (context, snapshot) {
        final available = snapshot.data ?? false;
        if (!available) return const SizedBox.shrink();
        // v1.7.26: 监听 StorageService（ChangeNotifier）→ 切开关后 UI 实时更新（不再等重启）
        return ListenableBuilder(
          listenable: storage,
          builder: (context, _) {
            return FutureBuilder<bool>(
              future: storage.getBiometricLockEnabled(),
              builder: (context, snap) {
                final enabled = snap.data ?? false;
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  secondary: const Icon(Icons.lock_outline),
                  title: Text(zh ? '应用锁' : 'App Lock'),
                  subtitle: Text(
                    zh ? '每次打开应用需验证指纹/面部/锁屏密码' : 'Require fingerprint/face/screen lock to open app',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: enabled,
                  onChanged: (val) async {
                    if (val) {
                      final authed = await BiometricService.authenticate(
                        reason: zh ? '请验证身份以开启生物识别锁' : 'Please authenticate to enable biometric lock',
                      );
                      if (!authed) return;
                    }
                    await storage.setBiometricLockEnabled(val);
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
