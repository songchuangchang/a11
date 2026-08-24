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
    final systemPlugins = allPlugins.where((p) => p.source == PluginSource.system).toList();
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
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
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
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'v${updateInfo.latestVersion}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
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
                color: Colors.orange,
                tooltip: isZh ? '更新' : 'Update',
                onPressed: () => _updatePlugin(plugin, updateInfo, registry, isZh),
              ),
            if (canUninstall)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: Colors.redAccent,
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
    
    try {
      // TODO: 实现实际的插件更新逻辑（下载新版本并替换）
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isZh ? '更新功能开发中...' : 'Update feature in development...'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isZh ? '更新失败：$e' : 'Update failed: $e'),
        backgroundColor: Colors.redAccent,
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
