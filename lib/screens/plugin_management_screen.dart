import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../plugins/plugin_interface.dart';
import '../plugins/plugin_registry.dart';
import '../services/plugin_update_service.dart';
import 'plugin_market_screen.dart';

class PluginManagementScreen extends StatefulWidget {
  const PluginManagementScreen({super.key});

  @override
  State<PluginManagementScreen> createState() => _PluginManagementScreenState();
}

class _PluginManagementScreenState extends State<PluginManagementScreen> {
  List<PluginUpdateInfo> _updates = [];
  bool _checkingUpdates = false;

  @override
  void initState() {
    super.initState();
    _checkUpdates();
  }

  Future<void> _checkUpdates() async {
    if (_checkingUpdates) return;
    setState(() => _checkingUpdates = true);
    try {
      final registry = context.read<PluginRegistry>();
      final updates = await PluginUpdateService.checkAllUpdates(registry);
      if (mounted) {
        setState(() {
          _updates = updates;
          _checkingUpdates = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkingUpdates = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final registry = context.watch<PluginRegistry>();
    final allPlugins = registry.plugins;
    // v1.7.36：联网搜索已内置为默认能力（不可关），不再出现在插件管理页
    final systemPlugins = allPlugins
        .where((p) =>
            p.source == PluginSource.system &&
            p.metadata.id != PluginRegistry.kSearchPluginId)
        .toList();
    final installedPlugins = allPlugins.where((p) => p.source == PluginSource.installed).toList();
    final isEmpty = allPlugins.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? '插件管理 / Plugin Manager' : 'Plugin Manager / 插件管理'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PluginMarketScreen()),
          );
        },
        icon: const Icon(Icons.storefront),
        label: Text(isZh ? '插件市场' : 'Market'),
      ),
      body: isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.extension_off,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isZh ? '暂无插件' : 'No plugins yet',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                if (systemPlugins.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    child: Text(
                      isZh ? '🟢 系统内置' : '🟢 System Built-in',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  Card(
                    child: Column(
                      children: systemPlugins.map((p) => _buildPluginTile(p, registry, isZh)).toList(),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (installedPlugins.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    child: Text(
                      isZh ? '🔵 已安装第三方' : '🔵 Installed Third-party',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  Card(
                    child: Column(
                      children: installedPlugins.map((p) => _buildPluginTile(p, registry, isZh)).toList(),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildPluginTile(ReActPlugin plugin, PluginRegistry registry, bool isZh) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = switch (plugin.source) {
      PluginSource.system => Icons.extension,
      PluginSource.installed => Icons.install_desktop,
      PluginSource.market => Icons.shop,
    };
    final enabled = registry.isEnabled(plugin.metadata.id);
    // v1.6.10 build44：第三方插件可卸载（系统内置插件不可卸载，只能禁用）
    final canUninstall = plugin.source != PluginSource.system;
    
    // v1.7.5: 检查是否有更新
    final updateInfo = _updates.where((u) => u.pluginId == plugin.metadata.id).firstOrNull;
    final hasUpdate = updateInfo != null && updateInfo.hasUpdate;

    return InkWell(
      onLongPress: () => _showPluginDetails(plugin, isZh),
      child: ListTile(
        leading: Icon(icon, color: colorScheme.primary),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${plugin.metadata.name}  v${plugin.metadata.version}',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            if (hasUpdate)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.tertiary,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'v${updateInfo.latestVersion}',
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.onPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Text(
          plugin.metadata.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasUpdate)
              IconButton(
                icon: const Icon(Icons.system_update, size: 20),
                color: colorScheme.tertiary,
                tooltip: isZh ? '更新' : 'Update',
                onPressed: () => _updatePlugin(plugin, updateInfo, registry, isZh),
              ),
            if (canUninstall)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: colorScheme.error,
                tooltip: isZh ? '卸载' : 'Uninstall',
                onPressed: () => _confirmUninstall(plugin, registry, isZh),
              ),
            Switch(value: enabled, onChanged: (v) => registry.setEnabled(plugin.metadata.id, v)),
          ],
        ),
      ),
    );
  }
  
  Future<void> _updatePlugin(
    ReActPlugin plugin,
    PluginUpdateInfo updateInfo,
    PluginRegistry registry,
    bool isZh,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '更新「${plugin.metadata.name}」？' : 'Update "${plugin.metadata.name}"?'),
        content: Text(isZh
            ? '当前版本：v${updateInfo.currentVersion}\n最新版本：v${updateInfo.latestVersion}\n\n更新后将自动启用新版本。'
            : 'Current: v${updateInfo.currentVersion}\nLatest: v${updateInfo.latestVersion}\n\nThe new version will be enabled automatically after update.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isZh ? '更新' : 'Update'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // v1.7.14：接入 PluginUpdateService.updatePlugin（service 在 v1.7.12 已实现，
    // 但 plugin_management_screen 一直留着 v1.7.5 的 TODO 占位，导致点"更新"按钮
    // 永远只显示开发中提示而不真正执行更新。本行把 UI 接入 service，让 Skill 重新
    // 下载 SKILL.md 覆盖安装、MCP 重新 fetch registry + installRemoteMcp 真正生效。
    try {
      final (success, message) =
          await PluginUpdateService.updatePlugin(updateInfo, registry);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success
            ? (isZh ? '更新成功: $message' : 'Update successful: $message')
            : (isZh ? '更新失败: $message' : 'Update failed: $message')),
        backgroundColor: success ? colorScheme.primary : colorScheme.error,
        behavior: SnackBarBehavior.floating,
      ));
      // 更新成功 → 移除 _updates 里对应条目，更新按钮自动消失（registry.plugins 已
      // 被 installDeclarative / installRemoteMcp 内部 notifyListeners 触发 rebuild，
      // 新版本号会从 plugin.metadata.version 反映出来）
      if (success) {
        setState(() {
          _updates = _updates
              .where((u) => u.pluginId != updateInfo.pluginId)
              .toList();
        });
      }
    } catch (e) {
      // PluginUpdateService.updatePlugin 内部已 try-catch 返回 (false, msg)，
      // 这里是双保险（理论上不应到达）
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isZh ? '更新失败：$e' : 'Update failed: $e'),
        backgroundColor: colorScheme.error,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _confirmUninstall(ReActPlugin plugin, PluginRegistry registry, bool isZh) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '卸载「${plugin.metadata.name}」？' : 'Uninstall "${plugin.metadata.name}"?'),
        content: Text(isZh
            ? '卸载后将移除该插件及其配置，需要重新安装才能恢复。'
            : 'This will remove the plugin and its config. Reinstall to restore.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(isZh ? '取消' : 'Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isZh ? '卸载' : 'Uninstall'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await registry.uninstall(plugin.metadata.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isZh ? '已卸载 ${plugin.metadata.name}' : '${plugin.metadata.name} uninstalled'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  void _showPluginDetails(ReActPlugin plugin, bool isZh) {
    final m = plugin.metadata;
    showDialog(
      context: context,
      builder: (_) => AboutDialog(
        applicationName: '${m.name} v${m.version}',
        applicationIcon: Icon(
          Icons.extension,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        children: [
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(isZh ? '作者' : 'Author'),
            subtitle: Text(m.author.isEmpty ? '-' : m.author),
          ),
          ListTile(
            leading: const Icon(Icons.tag),
            title: Text(isZh ? '版本' : 'Version'),
            subtitle: Text(m.version),
          ),
          if (m.homepage.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(isZh ? '主页' : 'Homepage'),
              subtitle: Text(m.homepage),
            ),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: Text(isZh ? '最小 App 版本' : 'Min App Version'),
            subtitle: Text(m.minAppVersion),
          ),
          if (m.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: m.tags
                    .map((t) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(t,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w500)),
                        ))
                    .toList(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              m.description,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
