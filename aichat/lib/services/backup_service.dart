import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../constants.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/web_search_config.dart';
import '../models/mcp_market_models.dart';
import '../plugins/plugin_interface.dart';
import 'logger_service.dart';
import 'storage_service.dart';

/// v1.3.8：导出/导入服务
///
/// 用户需求：“能加入一个导出和导入功能，可以选择导出了什么，是否需要导出 API 等”
///
/// 已和用户对齐：
///   ① 导出范围：全量数据（API 配置 + 聊天记录 + 搜索设置）
///   ② API key 等敏感信息：导出时让用户勾选是否包含（默认不含）
///   ③ 文件格式：单个 JSON 文件
///   ④ 导入策略：让用户选「合并到现有数据」或「清空后覆盖」
///
/// JSON schema（schemaVersion=1）：
/// ```json
/// {
///   "schemaVersion": 1,
///   "exportedAt": "2026-08-19T...",
///   "appVersion": "1.3.7",
///   "includeKeys": true,
///   "data": {
///     "apiConfigs":     [ {ApiConfig.toMap}, ... ],
///     "conversations":  [ {Conversation.toMap}, ... ],
///     "messages":       [ {ChatMessage.toMap}, ... ],
///     "webSearchConfig": {WebSearchConfig.toMap}
///   }
/// }
/// ```
class BackupService {
  static const int kSchemaVersion = 1;
  // v1.4.3：appVersion 集中管理；v1.6.4 迁移到 ../constants.dart 避免循环依赖
  static const String kAppVersion = kAppVersionConst;

  final StorageService _storage;
  final LoggerService _logger = LoggerService.instance;
  final _uuid = const Uuid();

  BackupService(this._storage);

  // ===========================================================================
  // 导出
  // ===========================================================================

  /// 导出全部数据为 JSON 字符串
  ///
  /// [includeKeys]：true 时保留 apiKey / tavilyApiKey 原值；false 时置空字符串
  Future<String> exportAll({required bool includeKeys}) async {
    final apiConfigs = await _storage.getApiConfigs();
    final conversations = await _storage.getConversations();
    final webSearchCfg = await _storage.getWebSearchConfig();
    // ✅ NEW-BUG-01 修复：导出 plugins 表全量数据（包含市场安装的第三方插件 + 系统插件 enabled 状态）
    final allPlugins = await _storage.loadAllPlugins();

    // 拉所有对话的消息（每个对话一组）
    final allMessages = <Map<String, dynamic>>[];
    for (final conv in conversations) {
      final msgs = await _storage.getMessages(conv.id);
      allMessages.addAll(msgs.map((m) => m.toMap()));
    }

    // 处理敏感字段
    final apiConfigsMap = apiConfigs.map((c) {
      final m = c.toMap();
      if (!includeKeys) {
        m['apiKey'] = '';
      }
      return m;
    }).toList();

    final webSearchMap = webSearchCfg.toMap();
    if (!includeKeys) {
      // v1.6.8 修复 Bug#1：导出时清空全部 4 个搜索服务商 API Key（之前只清了 tavily，漏掉 serpApiKey/braveApiKey/googleCseApiKey 三个，导致明文写入导出文件）
      webSearchMap['tavilyApiKey'] = '';
      webSearchMap['serpApiKey'] = '';
      webSearchMap['braveApiKey'] = '';
      webSearchMap['googleCseApiKey'] = '';
    }

    final export = <String, dynamic>{
      'schemaVersion': kSchemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'appVersion': kAppVersion,
      'includeKeys': includeKeys,
      'data': {
        'apiConfigs': apiConfigsMap,
        'conversations': conversations.map((c) => c.toMap()).toList(),
        'messages': allMessages,
        'webSearchConfig': webSearchMap,
        // ✅ NEW-BUG-01：plugins 数组加入导出 JSON
        'plugins': allPlugins,
      },
    };

    final json = const JsonEncoder.withIndent('  ').convert(export);
    _logger.info(
        '[Backup] Exported: ${apiConfigsMap.length} configs, '
        '${conversations.length} conversations, '
        '${allMessages.length} messages, '
        '${allPlugins.length} plugins, '
        'includeKeys=$includeKeys',
        tag: 'Backup');
    return json;
  }

  /// 把 JSON 写到用户可见的下载目录，返回文件路径
  ///
  /// v1.4.3 修复 Bug #7：文件名后缀从 .json 改 .txt（Android 对 .json 识别不友好，教训#29）
  /// v1.4.3 修复 Bug #8：异常包装 + 日志，避免直接抛 FileSystemException 让 UI 难处理
  /// 文件名格式：aichat_backup_YYYYMMDD_HHMMSS.txt
  Future<String> writeExportToFile(String json, {String? customPath}) async {
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final fileName = 'aichat_backup_$stamp.txt';

    String outPath = '';
    try {
      if (customPath != null && customPath.isNotEmpty) {
        outPath = p.join(customPath, fileName);
      } else {
        // 默认放到下载目录下的 AIChat_Downloads/
        Directory? baseDir;
        try {
          baseDir = await getDownloadsDirectory();
        } catch (_) {}
        if (baseDir == null) {
          // 回退：app documents 目录
          final appDir = await getApplicationDocumentsDirectory();
          baseDir = appDir;
        }
        final dir = Directory(p.join(baseDir.path, 'Nexus_Downloads'));
        if (!dir.existsSync()) {
          await dir.create(recursive: true);
        }
        outPath = p.join(dir.path, fileName);
      }

      final file = File(outPath);
      await file.writeAsString(json, flush: true);
      _logger.info('[Backup] Export file written: $outPath', tag: 'Backup');
      return outPath;
    } catch (e, st) {
      _logger.error('[Backup] writeExportToFile failed: $outPath',
          error: e, stack: st, tag: 'Backup');
      throw _BackupIOException('写入导出文件失败: $e\n目标路径: $outPath');
    }
  }

  // ===========================================================================
  // 导入
  // ===========================================================================

  /// 从 JSON 字符串导入数据
  ///
  /// [merge]：true = 追加到现有数据（UUID 冲突时给导入项生成新 UUID 并更新引用）
  ///          false = 清空所有表后重新插入
  ///
  /// 返回统计：导入的 apiConfigs / conversations / messages 数量
  Future<ImportStats> importFromString(String jsonStr,
      {required bool merge}) async {
    final dynamic decoded = json.decode(jsonStr);
    if (decoded is! Map) {
      throw const _BackupFormatException('JSON 根节点必须是对象');
    }
    final root = decoded.cast<String, dynamic>();
    final schemaVersion = (root['schemaVersion'] as int?) ?? 1;
    if (schemaVersion > kSchemaVersion) {
      throw _BackupFormatException(
          '文件 schemaVersion=$schemaVersion 比当前支持版本($kSchemaVersion)新，请升级 App 后再导入');
    }
    final data = root['data'] as Map?;
    if (data == null) {
      throw const _BackupFormatException('JSON 缺少 data 字段');
    }

    final apiConfigsRaw = (data['apiConfigs'] as List?) ?? [];
    final conversationsRaw = (data['conversations'] as List?) ?? [];
    final messagesRaw = (data['messages'] as List?) ?? [];
    final webSearchRaw = data['webSearchConfig'] as Map?;
    // ✅ NEW-BUG-01 修复：读取 plugins 数组（老版本备份没有 plugins 字段时用空列表兜底）
    final pluginsRaw = (data['plugins'] as List?) ?? [];

    final apiConfigs = apiConfigsRaw
        .map((m) => ApiConfig.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    final conversations = conversationsRaw
        .map((m) => Conversation.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    final messages = messagesRaw
        .map((m) => ChatMessage.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
    // plugins 就是 Map<String,dynamic>，不需要 fromMap，后面直接 upsertPlugin 到 DB
    final plugins =
        pluginsRaw.map((m) => Map<String, dynamic>.from(m as Map)).toList();
    WebSearchConfig? webSearchCfg;
    if (webSearchRaw != null) {
      webSearchCfg =
          WebSearchConfig.fromMap(Map<String, dynamic>.from(webSearchRaw));
    }

    if (!merge) {
      // 覆盖模式：先清空所有表（保留 web_search_configs singleton 行结构）
      await _clearAllTables();
    }

    // 合并模式：UUID 冲突时给导入项生成新 UUID，并维护 ID 映射
    // 覆盖模式：原样插入（库已清空，理论上不会有冲突）
    final apiConfigIdMap = <String, String>{}; // oldId -> newId
    final conversationIdMap = <String, String>{};

    int apiConfigCount = 0;
    int conversationCount = 0;
    int messageCount = 0;
    // ✅ NEW-BUG-01：插件导入计数
    int pluginCount = 0;

    for (final cfg in apiConfigs) {
      String newId = cfg.id;
      if (merge) {
        final existing = await _storage.getApiConfig(cfg.id);
        if (existing != null) {
          // ID 冲突，生成新 UUID
          newId = _uuid.v4();
          apiConfigIdMap[cfg.id] = newId;
        }
      }
      // v1.4.3 修复 Bug #3：重建 ApiConfig 时补齐 topP 字段
      // 之前漏 topP → 合并冲突时 topP 重置为默认 1.0
      // v1.7.9：补 cachedModels → 冲突重建时模型列表缓存不再丢失
      final toSave = newId == cfg.id
          ? cfg
          : ApiConfig(
              id: newId,
              name: cfg.name,
              baseUrl: cfg.baseUrl,
              apiKey: cfg.apiKey,
              model: cfg.model,
              systemPrompt: cfg.systemPrompt,
              temperature: cfg.temperature,
              topP: cfg.topP,
              maxTokens: cfg.maxTokens,
              cachedModels: cfg.cachedModels,
            );
      await _storage.saveApiConfig(toSave);
      apiConfigCount++;
    }

    for (final conv in conversations) {
      String newId = conv.id;
      String? newApiConfigId;
      if (merge) {
        final existing = await _storage.getConversation(conv.id);
        if (existing != null) {
          newId = _uuid.v4();
          conversationIdMap[conv.id] = newId;
        }
        // 如果 API 配置被换了新 ID，对话的 apiConfigId 也要跟着换
        newApiConfigId = apiConfigIdMap[conv.apiConfigId] ?? conv.apiConfigId;
      } else {
        newApiConfigId = conv.apiConfigId;
      }
      // v1.4.3 修复 Bug #2：重建 Conversation 时补齐 6 个对话级设置字段
      // 之前漏 contextLimit/temperature/topP/enable20sCheck/contextAuto/autoCompress
      // → 合并冲突时对话独立参数全部丢失回默认
      final toSave = (newId == conv.id && newApiConfigId == conv.apiConfigId)
          ? conv
          : Conversation(
              id: newId,
              title: conv.title,
              apiConfigId: newApiConfigId,
              lastMessage: conv.lastMessage,
              contextLimit: conv.contextLimit,
              temperature: conv.temperature,
              topP: conv.topP,
              enable20sCheck: conv.enable20sCheck,
              contextAuto: conv.contextAuto,
              autoCompress: conv.autoCompress,
              updatedAt: conv.updatedAt,
              createdAt: conv.createdAt,
            );
      // 直接写库，绕过 saveConversation 的“更新 lastMessage/updatedAt”逻辑
      await _storage.saveConversation(toSave);
      conversationCount++;
    }

    for (final msg in messages) {
      String newConvId = msg.conversationId;
      if (merge) {
        newConvId = conversationIdMap[msg.conversationId] ?? msg.conversationId;
      }
      final toSave = newConvId == msg.conversationId
          ? msg
          : ChatMessage(
              id: msg.id,
              conversationId: newConvId,
              role: msg.role,
              content: msg.content,
              createdAt: msg.createdAt,
            );
      // 消息附件列表是非 final 字段，复制过来
      // v1.6.8 修复 Bug#2：toSave IS msg 时 toSave.attachments 和 msg.attachments 是同一对象，
      // list.addAll(list) 抛 ConcurrentModificationError，导致覆盖模式或无 UUID 冲突的合并模式下
      // 导入任何带附件消息都会崩溃。用 identical 守卫避免自引用。
      if (!identical(toSave, msg)) {
        toSave.attachments.addAll(msg.attachments);
      }
      // v1.4.3 修复 Bug #1（教训#30）：绕过 saveMessage 直接 db.insert
      // saveMessage 会更新 conversation.updatedAt 为 NOW → 导入后对话排序错乱
      await _insertMessageRaw(toSave);
      messageCount++;
    }

    // WebSearchConfig 是 singleton，合并/覆盖都直接覆盖（v1.3.8 决定不合并 KV 级字段）
    if (webSearchCfg != null) {
      // 如果导入的文件不含 key（includeKeys=false），保留当前库的 key 不覆盖
      final currentCfg = await _storage.getWebSearchConfig();
      final importedIncludeKeys = (root['includeKeys'] as bool?) ?? true;
      // v1.4.3 修复 Bug #5：所有 4 个 API Key 字段统一应用“保留当前”逻辑
      // 之前只 tavilyApiKey 享受，serpApiKey/braveApiKey/googleCseApiKey 会被空字符串直接覆盖
      // → 用户在 A 设备填好的 SerpAPI/Brave/Google CSE Key 导入不含 Key 的备份到 B 设备后被清空
      String pickKey(String imported, String current) {
        if (importedIncludeKeys) return imported;
        return current.isNotEmpty ? current : '';
      }

      // v1.4.3 修复 Bug #4：WebSearchConfig 重建补齐 5 个 v1.3.9 新增字段
      // 之前漏 serpApiKey/serpapiEngine/braveApiKey/googleCseApiKey/googleCseId
      // → 导入后 SerpAPI/Brave/Google CSE 三服务商配置全部丢失
      final merged = WebSearchConfig(
        webSearchEnabled: webSearchCfg.webSearchEnabled,
        provider: webSearchCfg.provider,
        tavilyApiKey:
            pickKey(webSearchCfg.tavilyApiKey, currentCfg.tavilyApiKey),
        tavilySearchDepth: webSearchCfg.tavilySearchDepth,
        tavilyMaxResults: webSearchCfg.tavilyMaxResults,
        searxngInstanceUrl: webSearchCfg.searxngInstanceUrl,
        serpApiKey: pickKey(webSearchCfg.serpApiKey, currentCfg.serpApiKey),
        serpapiEngine: webSearchCfg.serpapiEngine,
        braveApiKey: pickKey(webSearchCfg.braveApiKey, currentCfg.braveApiKey),
        googleCseApiKey:
            pickKey(webSearchCfg.googleCseApiKey, currentCfg.googleCseApiKey),
        googleCseId: webSearchCfg.googleCseId,
        maxSnippetCharsPerResult: webSearchCfg.maxSnippetCharsPerResult,
        maxResultsInject: webSearchCfg.maxResultsInject,
        persistentWebSearchToggle: webSearchCfg.persistentWebSearchToggle,
        reactEnabled: webSearchCfg.reactEnabled,
        reactMaxRounds: webSearchCfg.reactMaxRounds,
        reactAutoMode: webSearchCfg.reactAutoMode,
        githubProxyUrl: webSearchCfg.githubProxyUrl,
        verboseLogging: webSearchCfg.verboseLogging,
        // v1.7.9 (M3 修复)：补齐 v1.7.5 安全审查 5 字段，
        // 之前漏掉 → 导入备份会把 SkillSpector/MobSF 端点和 3 个开关静默重置为空/关
        skillspectorEndpoint: webSearchCfg.skillspectorEndpoint,
        enableSkillSecurityScan: webSearchCfg.enableSkillSecurityScan,
        enableMcpSecurityScan: webSearchCfg.enableMcpSecurityScan,
        mobsfEndpoint: webSearchCfg.mobsfEndpoint,
        enableApkSecurityScan: webSearchCfg.enableApkSecurityScan,
        // v1.7.10：本地扫描 2 字段（同 M3 教训：导入别静默重置）
        enableLocalScan: webSearchCfg.enableLocalScan,
        localScanRulesUrl: webSearchCfg.localScanRulesUrl,
        // v1.7.11：VirusTotal + MobSF API Key（同 M3 教训）
        virusTotalApiKey: webSearchCfg.virusTotalApiKey,
        enableVirusTotalScan: webSearchCfg.enableVirusTotalScan,
        mobsfApiKey: webSearchCfg.mobsfApiKey,
      );
      await _storage.saveWebSearchConfig(merged);
    }

    // ✅ NEW-BUG-01 修复：导入 plugins 数组 → DB plugins 表
    //   - 覆盖模式：_clearAllTables 已经删 plugins 表全部行，直接 replace 写即可
    //   - 合并模式：以 DB 现有 id 为准，冲突时 replace（导入备份的插件设置覆盖当前同 id 设置；若当前已有设置用户不想被覆盖，则应先手动卸载再 merge）
    for (final row in plugins) {
      try {
        // row 结构和 loadAllPlugins 返回一致：{id, name, version, source, author, description, enabled, installedAt, metadataJson}
        final sanitized = Map<String, dynamic>.from(row);
        final metadataRaw = sanitized['metadataJson'];
        if (metadataRaw is! String || metadataRaw.trim().isEmpty) {
          throw const FormatException('Plugin metadata is missing');
        }
        final decodedMetadata = jsonDecode(metadataRaw);
        if (decodedMetadata is! Map) {
          throw const FormatException('Plugin metadata is invalid');
        }
        final metadata =
            PluginMetadata.fromMap(Map<String, dynamic>.from(decodedMetadata));
        if (metadata.kind == PluginKind.mcpRemote) {
          InstalledMcpConfig.fromJson(metadata.extra);
          sanitized['enabled'] = 0;
        }
        // 强制重新计算 enabled/int 转换（容错：enabled 可能是 bool 或 int 或 String）
        final dynEnabled = sanitized['enabled'];
        if (dynEnabled is bool) {
          sanitized['enabled'] = dynEnabled ? 1 : 0;
        } else if (dynEnabled is int) {
          sanitized['enabled'] = dynEnabled == 0 ? 0 : 1;
        } else if (dynEnabled is String) {
          final s = dynEnabled.trim().toLowerCase();
          sanitized['enabled'] =
              (s == '1' || s == 'true' || s == 'yes' || s == 'on') ? 1 : 0;
        } else if (metadata.kind != PluginKind.mcpRemote) {
          sanitized['enabled'] = 1; // 兜底：默认启用，避免导入后全是 0 导致插件全禁用
        }
        // installedAt 容错：确保 int（毫秒）
        final dInstalledAt = sanitized['installedAt'];
        if (dInstalledAt is! int) {
          sanitized['installedAt'] = DateTime.now().millisecondsSinceEpoch;
        }
        await _storage.upsertPlugin(sanitized);
        pluginCount++;
      } catch (e, st) {
        // 单条插件失败不阻塞整体导入，记日志继续
        _logger.warn('[Backup] import plugin row failed: $row',
            cat: LogCat.backup, tag: 'Backup');
        _logger.error('[Backup] import plugin row error detail:',
            error: e, stack: st, cat: LogCat.backup, tag: 'Backup');
      }
    }

    _logger.info(
        '[Backup] Import ${merge ? "merge" : "overwrite"} done: '
        '$apiConfigCount configs, $conversationCount conversations, $messageCount messages, '
        '$pluginCount plugins',
        tag: 'Backup');

    return ImportStats(
      apiConfigs: apiConfigCount,
      conversations: conversationCount,
      messages: messageCount,
      plugins: pluginCount,
    );
  }

  /// 从文件路径导入
  Future<ImportStats> importFromFile(String filePath,
      {required bool merge}) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw _BackupFileNotFoundException(filePath);
    }
    final jsonStr = await file.readAsString();
    return importFromString(jsonStr, merge: merge);
  }

  // ===========================================================================
  // 私有：清空所有表（覆盖模式用）
  // ===========================================================================

  /// v1.4.3 修复 Bug #1（教训#30）：消息原始插入，绕过 saveMessage 的 conversation updatedAt 更新
  ///
  /// [StorageService.saveMessage] 会把 conversation.updatedAt 更新为 NOW，
  /// 导致导入老备份后所有对话按 NOW 排序顶到最前，顺序错乱。
  /// 这里直接 db.insert('messages') 不触发 conversation 时间戳更新。
  /// 保留 ConflictAlgorithm.replace 语义（同 ID 覆盖），与 saveMessage 一致。
  Future<void> _insertMessageRaw(ChatMessage msg) async {
    final database = await _storage.db;
    await database.insert('messages', msg.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _clearAllTables() async {
    final database = await _storage.db;
    // 注意删除顺序：先 messages（依赖 conversations）→ conversations（依赖 api_configs）
    // → api_configs → plugins → web_search_configs（保留 singleton 行，只 update）
    await database.delete('messages');
    await database.delete('conversations');
    await database.delete('api_configs');
    // ✅ NEW-BUG-01：覆盖模式同样清空 plugins 表，否则旧插件 + 老导入的插件会混在一起
    await database.delete('plugins');
    // web_search_configs 是 singleton，不删整行，让 importAll 后续覆盖
    _logger.info('[Backup] All tables cleared (overwrite mode, incl. plugins)',
        tag: 'Backup');
  }
}

/// 导入统计
class ImportStats {
  final int apiConfigs;
  final int conversations;
  final int messages;
  // ✅ NEW-BUG-01：新增 plugins 导入数量字段（给 UI 展示导入统计用）
  final int plugins;
  const ImportStats({
    required this.apiConfigs,
    required this.conversations,
    required this.messages,
    this.plugins = 0,
  });

  @override
  String toString() =>
      'ImportStats(configs=$apiConfigs, conversations=$conversations, messages=$messages, plugins=$plugins)';
}

class _BackupFormatException implements Exception {
  final String message;
  const _BackupFormatException(this.message);
  @override
  String toString() => 'BackupFormatException: $message';
}

class _BackupFileNotFoundException implements Exception {
  final String path;
  const _BackupFileNotFoundException(this.path);
  @override
  String toString() => 'BackupFileNotFoundException: $path';
}

/// v1.4.3 修复 Bug #8：导出文件写入失败的自定义异常
class _BackupIOException implements Exception {
  final String message;
  const _BackupIOException(this.message);
  @override
  String toString() => 'BackupIOException: $message';
}
