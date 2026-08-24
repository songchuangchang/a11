import 'dart:convert';

import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../models/mcp_market_models.dart';
import '../services/mcp_client_service.dart';
import '../services/storage_service.dart';
import 'plugin_interface.dart';
import 'plugin_context.dart';
import 'installed_dynamic_plugin.dart';
import 'installed_mcp_plugin.dart';

class PluginRegistry extends ChangeNotifier {
  final Map<String, ReActPlugin> _registry = {};
  final Map<String, ReActPlugin> _fallbacks = {};
  final Map<String, bool> _enabledMap = {};
  final StorageService? _storage;
  final McpClientService Function()? _mcpClientFactory;
  // v1.6.9 build42：每个插件 id 的 setEnabled 互斥锁（Future 串行队列）
  // 避免用户快速连点开关时：第1次 await 写DB(false)覆盖第2次内存=true，重启后状态回滚
  final Map<String, Future<void>> _enableLocks = {};
  ReActPlugin? _fallbackPlugin;

  /// 联网搜索插件 id（与 builtin_plugins.dart SearchPlugin 的 metadata.id 一致）
  static const String kSearchPluginId = 'nexus.builtin.search';

  /// AI 自我终止判定插件 id（与 builtin_plugins.dart SelfCheckPlugin 一致）
  static const String kSelfCheckPluginId = 'nexus.builtin.self_check';

  /// 文件与应用下载插件 id（与 builtin_plugins.dart DownloadPlugin 一致）
  static const String kDownloadPluginId = 'nexus.builtin.download';

  PluginRegistry({StorageService? storage, McpClientService Function()? mcpClientFactory})
      : _storage = storage,
        _mcpClientFactory = mcpClientFactory {
    _initFromStorage();
  }

  Future<void> _initFromStorage() async {
    try {
      final s = _storage ?? StorageService.instance;
      if (!s.isInitialized) await s.init();

      // ✅ NEW-BUG-02 修复：从 DB plugins 表重新注册所有「非 system 插件」到内存
      //   - system 插件是 main.dart 里 registerBuiltinPlugins() 手动注册的（真实有 handle 实现）
      //     为避免重复注册/覆盖真实 handle 实现 → 跳过 source=system 的行
      //   - installed/community/market 来源插件都是占位（InstalledDynamicPlugin），
      //     需要从 DB 重新构造，否则重启后内存没对象 → 已安装列表空/prompt 不生效/dispatch 不命中
      try {
        final rows = await s.loadAllPlugins();
        for (final row in rows) {
          final src = (row['source'] as String?) ?? '';
          // 系统插件：main.dart 已经真正 register 过真实实现，跳过
          if (src == PluginSource.system.name) continue;
          // 已注册过（例如 market 安装后当时就 register 了）：跳过（避免重复）
          final id = row['id'] as String?;
          if (id == null || id.isEmpty) continue;
          if (_registry.containsKey(id)) continue;
          try {
            final plugin = InstalledDynamicPlugin.fromDbRow(row);
            // 注册到 registry（触发 dispatch/prompt 生效），同时 update fallback map
            register(plugin);
          } catch (e, st) {
            // 单条插件重建失败记录日志，继续其他插件（不阻塞整体启动）
            debugPrint(
                '[PluginRegistry] reconstruct installed plugin failed: $id, $e $st');
          }
        }
      } catch (e, st) {
        debugPrint('[PluginRegistry] loadAllPlugins reload failed: $e $st');
      }

      final states = await _safeLoadPluginStates(s);
      states.forEach((key, value) {
        if (value is bool) {
          _enabledMap[key] = value;
        } else if (value is int) {
          _enabledMap[key] = value == 1;
        }
      });
    } catch (_) {}
    notifyListeners();
  }

  Future<dynamic> _safeLoadPluginStates(StorageService s) async {
    try {
      final r = await (s as dynamic).loadPluginStates();
      if (r is Map<String, bool>) return r;
      if (r is Map<String, dynamic>) return r;
      return <String, bool>{};
    } catch (_) {
      return <String, bool>{};
    }
  }

  Future<void> _safePersistEnabledMap() async {
    try {
      final s = _storage ?? StorageService.instance;
      // StorageService 没有批量保存接口，逐个保存
      for (final entry in _enabledMap.entries) {
        await (s as dynamic).savePluginState(entry.key, enabled: entry.value);
      }
    } catch (_) {}
  }

  /// v1.6.9 build42 修复问题2：联网搜索「插件开关」与「系统设置开关」双向同步。
  /// 这里是 registry → config 单向：插件管理里开关 SearchPlugin 时，同步写
  /// WebSearchConfig.webSearchEnabled，使设置页开关 / 输入框 🌐 保持一致。
  /// （反向 config → registry 在 settings_screen 的开关 onChanged 里调 setEnabled 完成。）
  Future<void> _syncSearchEnabledToConfig(bool value) async {
    try {
      final s = _storage ?? StorageService.instance;
      if (!s.isInitialized) await s.init();
      final cfg = await s.getWebSearchConfig();
      await s.saveWebSearchConfig(cfg.copyWith(webSearchEnabled: value));
    } catch (_) {}
  }

  void register(ReActPlugin plugin) {
    final id = plugin.metadata.id;
    _registry[id] = plugin;
    _fallbacks[plugin.triggerType] = plugin;
    if (!_enabledMap.containsKey(id)) {
      _enabledMap[id] = plugin.source == PluginSource.system;
    }
    notifyListeners();
  }

  void registerAll(List<ReActPlugin> plugins) {
    for (final p in plugins) {
      register(p);
    }
  }

  void setFallback(ReActPlugin? plugin) {
    _fallbackPlugin = plugin;
  }

  /// v1.6.10 build44：完整卸载插件（内存 + DB），供插件管理界面删除第三方插件用。
  /// 清理：_registry（注册表）+ _fallbacks（triggerType 映射）+ _enabledMap（启用状态）+ plugins 表。
  Future<void> installDeclarative(PluginMetadata metadata) async {
    final s = _storage ?? StorageService.instance;
    if (!s.isInitialized) await s.init();
    await s.upsertPlugin({
      'id': metadata.id,
      'name': metadata.name,
      'version': metadata.version,
      'source': PluginSource.installed.name,
      'author': metadata.author,
      'description': metadata.description,
      'enabled': 1,
      'installedAt': DateTime.now().millisecondsSinceEpoch,
      'metadataJson': jsonEncode(metadata.toMap()),
    });
    register(
      InstalledDynamicPlugin(
          metadata: metadata, source: PluginSource.installed),
    );
    await setEnabled(metadata.id, true);
  }

  Future<void> installRemoteMcp(
    McpRegistryServer server, {
    McpClientService? client,
  }) async {
    if (_registry.containsKey(server.name) &&
        _registry[server.name]!.metadata.kind != PluginKind.mcpRemote) {
      throw const FormatException('A non-MCP plugin already uses this id');
    }
    final mcpClient = client ?? McpClientService();
    final previous = _registry[server.name];
    final previousEnabled = _enabledMap[server.name];
    final s = _storage ?? StorageService.instance;
    if (!s.isInitialized) await s.init();
    final previousRows = await s.loadAllPlugins();
    Map<String, dynamic>? previousRow;
    for (final row in previousRows) {
      if (row['id'] == server.name) {
        previousRow = row;
        break;
      }
    }
    try {
      final rawTools =
          await mcpClient.discoverTools(server.endpoint.toString());
      final tools = rawTools
          .map((tool) => McpToolDefinition.fromJson(tool))
          .toList(growable: false);
      if (tools.isEmpty) throw const FormatException('MCP server has no tools');
      final config = InstalledMcpConfig(
        serverName: server.name,
        serverVersion: server.version,
        endpoint: server.endpoint,
        protocolVersion: '2025-03-26',
        tools: tools,
        lastVerifiedAt: DateTime.now().toUtc(),
      );
      final metadata = PluginMetadata(
        id: server.name,
        name: server.title,
        version: server.version,
        author: 'MCP Registry',
        description: server.description,
        homepage: server.homepage?.toString() ?? '',
        promptProtocol:
            'MCP tools are available through plugin_id="${server.name}".',
        tags: const ['MCP', '公开'],
        kind: PluginKind.mcpRemote,
        triggerType: 'mcp_call',
        extra: config.toJson(),
      );
      final s = _storage ?? StorageService.instance;
      if (!s.isInitialized) await s.init();
      await s.upsertPlugin({
        'id': metadata.id,
        'name': metadata.name,
        'version': metadata.version,
        'source': PluginSource.installed.name,
        'author': metadata.author,
        'description': metadata.description,
        'enabled': 1,
        'installedAt': DateTime.now().millisecondsSinceEpoch,
        'metadataJson': jsonEncode(metadata.toMap()),
      });
      final installed = InstalledMcpPlugin.fromMetadata(metadata);
      register(installed);
      _enabledMap[metadata.id] = true;
      notifyListeners();
      await _safePersistEnabledMap();
    } catch (_) {
      final current = _registry[server.name];
      if (current is InstalledMcpPlugin && !identical(current, previous)) {
        current.close();
      }
      if (previous == null) {
        _registry.remove(server.name);
        // L-3 修复：回滚已注册插件时同步清理其写入的 triggerType fallback 映射。
        if (current != null &&
            identical(_fallbacks[current.triggerType], current)) {
          _fallbacks.remove(current.triggerType);
        }
      } else {
        _registry[server.name] = previous;
        _fallbacks[previous.triggerType] = previous;
      }
      if (previousEnabled == null) {
        _enabledMap.remove(server.name);
      } else {
        _enabledMap[server.name] = previousEnabled;
      }
      try {
        if (previousRow == null) {
          await s.deletePlugin(server.name);
        } else {
          await s.upsertPlugin(previousRow);
        }
      } catch (_) {}
      notifyListeners();
      rethrow;
    } finally {
      if (client == null) mcpClient.close();
    }
  }

  Future<void> uninstall(String id) async {
    final plugin = _registry[id];
    if (plugin?.source == PluginSource.system) {
      throw StateError('System plugins cannot be uninstalled');
    }
    final s = _storage ?? StorageService.instance;
    if (!s.isInitialized) await s.init();
    await s.deletePlugin(id);
    if (plugin is InstalledMcpPlugin) {
      plugin.close();
    }
    _fallbacks.removeWhere((_, v) => v.metadata.id == id);
    _registry.remove(id);
    _enabledMap.remove(id);
    notifyListeners();
    await _safePersistEnabledMap();
  }

  bool isEnabled(String id) {
    return _enabledMap[id] ?? (id == '__fallback_unknown__' ? true : false);
  }

  Future<void> setEnabled(String id, bool value) async {
    // per-id 串行队列：快速连点 A->B 时 B 一定等 A 的 await 持久化完成后再读内存最新值写 DB
    final currentLock = _enableLocks[id];
    final next = Future<void>(() async {
      try {
        if (currentLock != null) await currentLock;
      } catch (_) {}
      if (value && (_enabledMap[id] ?? false) == false &&
          _registry[id] is InstalledMcpPlugin) {
        await _refreshMcpPlugin(id);
      }
      _enabledMap[id] = value;
      notifyListeners();
      await _safePersistEnabledMap();
      // v1.6.9 build42 修复问题2：联网搜索插件开关 → 同步写 WebSearchConfig.webSearchEnabled
      if (id == kSearchPluginId) {
        await _syncSearchEnabledToConfig(value);
      }
    });
    _enableLocks[id] = next;
    // ignore: avoid_catches_without_on_clauses
    next.then((_) {
      // 完成后如果当前 still == next，则清 key 减少内存占用
      if (identical(_enableLocks[id], next)) _enableLocks.remove(id);
    }, onError: (_) {
      if (identical(_enableLocks[id], next)) _enableLocks.remove(id);
    });
    return next;
  }

  Future<void> _refreshMcpPlugin(String id) async {
    final current = _registry[id];
    if (current is! InstalledMcpPlugin) return;
    final endpoint = current.metadata.extra['endpoint']?.toString() ?? '';
    final client = _mcpClientFactory?.call() ?? McpClientService();
    try {
      final rawTools = await client.discoverTools(endpoint);
      final tools = rawTools
          .map((tool) => McpToolDefinition.fromJson(tool))
          .toList(growable: false);
      if (tools.isEmpty) throw const FormatException('MCP server has no tools');
      final extra = Map<String, dynamic>.from(current.metadata.extra);
      extra['tools'] = tools.map((tool) => tool.toJson()).toList(growable: false);
      extra['lastVerifiedAt'] = DateTime.now().toUtc().toIso8601String();
      final metadata = current.metadata.copyWith(extra: extra);
      final replacement = InstalledMcpPlugin.fromMetadata(metadata);
      _registry[id] = replacement;
      _fallbacks[replacement.triggerType] = replacement;
      final s = _storage ?? StorageService.instance;
      if (!s.isInitialized) await s.init();
      final rows = await s.loadAllPlugins();
      Map<String, dynamic>? row;
      for (final item in rows) {
        if (item['id'] == id) {
          row = item;
          break;
        }
      }
      if (row != null) {
        await s.upsertPlugin({
          ...row,
          'metadataJson': jsonEncode(metadata.toMap()),
          'enabled': 1,
        });
      }
      final oldFallback = _fallbacks[current.triggerType];
      _fallbacks[current.triggerType] = replacement;
      try {
        _registry[id] = replacement;
        current.close();
      } catch (_) {
        _registry[id] = current;
        if (oldFallback == null) {
          _fallbacks.remove(current.triggerType);
        } else {
          _fallbacks[current.triggerType] = oldFallback;
        }
        replacement.close();
        rethrow;
      }
    } finally {
      client.close();
    }
  }

  List<ReActPlugin> get plugins =>
      List<ReActPlugin>.unmodifiable(_registry.values);

  List<ReActPlugin> listAll() => plugins;

  ReActPlugin? getById(String id) {
    return _registry[id];
  }

  Map<String, bool> get enabledSnapshot =>
      Map<String, bool>.unmodifiable(_enabledMap);

  /// v1.6.9 build42：给 PluginMarketScreen 安装流程写 DB 用。
  /// 因为 _storage 是 private，通过 StorageService.instance 兜底获取；
  /// 未初始化时返回 null，调用方应使用 await StorageService.instance.init()。
  StorageService? get storageOrNull {
    try {
      final s = _storage ?? StorageService.instance;
      return s;
    } catch (_) {
      return null;
    }
  }

  Future<bool> dispatch(
    BuildContext context,
    PluginContext pluginContext,
    String type,
    Map<String, dynamic> attrs,
  ) async {
    bool handled = false;
    ReActPlugin? primary;
    if (type == 'mcp_call') {
      final pluginId = attrs['pluginId']?.toString() ?? '';
      final target = _registry[pluginId];
      if (target == null ||
          !isEnabled(pluginId) ||
          (target.metadata.kind != PluginKind.mcpRemote &&
              target is! InstalledMcpPlugin)) {
        return false;
      }
      primary = target;
    }
    if (primary == null) {
      for (final p in _registry.values) {
        if (!isEnabled(p.metadata.id)) continue;
        if (p.triggerType == type) {
          primary = p;
          break;
        }
      }
    }
    if (type != 'mcp_call') primary ??= _fallbacks[type];
    if (primary == null) {
      final fb = _fallbackPlugin;
      if (fb != null && isEnabled(fb.metadata.id)) {
        try {
          await fb.handle(context, pluginContext, {'type': type, ...attrs});
          handled = true;
        } catch (_) {}
      }
      return handled;
    }
    if (!isEnabled(primary.metadata.id)) return false;
    try {
      await primary.handle(context, pluginContext, attrs);
      handled = true;
    } catch (e) {
      // v1.7.1 fix C2: 插件异常不再静默吞掉，注入错误消息让 AI 知道失败
      if (type == 'mcp_call') return false;
      final errorMsg = '<toolresult plugin_id="${primary.metadata.id}" tool="$type">插件执行失败: ${e.toString()}</toolresult>';
      pluginContext.addMessage(ChatMessage.create(
        conversationId: pluginContext.assistantMsg.conversationId,
        role: MessageRole.user,
        content: errorMsg,
      ));
      pluginContext.logger.error('Plugin ${primary.metadata.id} handle failed', 
          error: e, tag: 'Plugin');
    }
    if (!handled && type != 'mcp_call') {
      for (final p in _registry.values) {
        if (identical(p, primary)) continue;
        if (!isEnabled(p.metadata.id)) continue;
        final legacy = p.legacyTrigger;
        final raw =
            attrs['raw']?.toString() ?? attrs['content']?.toString() ?? '';
        if (legacy == null || raw.isEmpty) continue;
        final match = legacy.firstMatch(raw);
        if (match == null) continue;
        final legacyAttrs = Map<String, dynamic>.from(attrs);
        legacyAttrs['legacyMatch'] = match;
        legacyAttrs['_legacyRaw'] = raw;
        try {
          await p.handle(context, pluginContext, legacyAttrs);
          handled = true;
          break;
        } catch (_) {}
      }
    }
    return handled;
  }
}
