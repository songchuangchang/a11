import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'dart:convert';
import '../models/api_config.dart';
import '../models/conversation.dart';
import '../models/chat_message.dart';
import '../models/web_search_config.dart';
import 'logger_service.dart';

class StorageService extends ChangeNotifier {
  StorageService._internal();

  static final StorageService instance = StorageService._internal();

  final _logger = LoggerService.instance;
  Database? _db;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'aichat.db');
    _db = await openDatabase(
      path,
      version: 23,
      onCreate: (db, version) async {
        await _createV1Tables(db);
        await _createV2Tables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createV2Tables(db);
        }
        if (oldVersion < 3) {
          // v1.3.4：为已存在的 web_search_configs 表补 v1.3.1~v1.3.4 新增的列
          // 这些列在原始 _createV2Tables 的 CREATE TABLE 中遗漏，导致保存失败
          await _migrateV3WebSearchColumns(db);
        }
        if (oldVersion < 4) {
          // v1.3.6：messages 表补 attachments 列（存附件 JSON 数组）
          await _migrateV4MessagesAttachments(db);
        }
        if (oldVersion < 5) {
          await _migrateV5WebSearchColumns(db);
        }
        if (oldVersion < 6) {
          await _migrateV6ConversationSettings(db);
        }
        if (oldVersion < 7) {
          // v1.4.1：conversations 补 contextAuto（上下文自动/细化）+ autoCompress（自动压缩）
          await _migrateV7ContextColumns(db);
        }
        if (oldVersion < 8) {
          // v1.5.0：api_configs 补 cachedModels 列（缓存 GET /v1/models 拉取的模型列表 JSON）
          await _migrateV8CachedModels(db);
        }
        if (oldVersion < 9) {
          await _migrateV9Plugins(db);
        }
        if (oldVersion < 10) {
          await _migrateV10SecurityScan(db);
        }
        if (oldVersion < 11) {
          // v1.7.10：本地安全扫描（enableLocalScan 默认开 + 远程规则源 URL）
          await _ensureColumn(db, 'web_search_configs', 'enableLocalScan', 'INTEGER DEFAULT 1');
          await _ensureColumn(db, 'web_search_configs', 'localScanRulesUrl', "TEXT DEFAULT ''");
        }
        if (oldVersion < 12) {
          // v1.7.11：VirusTotal 云端查毒 + MobSF API Key
          await _ensureColumn(db, 'web_search_configs', 'virusTotalApiKey', "TEXT DEFAULT ''");
          await _ensureColumn(db, 'web_search_configs', 'enableVirusTotalScan', 'INTEGER DEFAULT 0');
          await _ensureColumn(db, 'web_search_configs', 'mobsfApiKey', "TEXT DEFAULT ''");
        }
        if (oldVersion < 13) {
          await _ensureColumn(db, 'messages', 'modelName', "TEXT DEFAULT ''");
          await _ensureColumn(db, 'conversations', 'isPinned', 'INTEGER DEFAULT 0');
        }
        if (oldVersion < 14) {
          await _ensureColumn(db, 'api_configs', 'templateId', "TEXT DEFAULT 'custom'");
        }
        if (oldVersion < 15) {
          await _ensureColumn(db, 'messages', 'retryOf', "TEXT DEFAULT ''");
          await _ensureColumn(db, 'messages', 'retryIndex', 'INTEGER DEFAULT 0');
        }
        if (oldVersion < 16) {
          await _ensureColumn(db, 'messages', 'reasoningSteps', "TEXT DEFAULT '[]'");
        }
        if (oldVersion < 17) {
          _logger.db('DB migrated to v17 (reasoningSteps phase/round support)');
        }
        if (oldVersion < 18) {
          await _ensureColumn(db, 'web_search_configs', 'biometricLockEnabled', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'web_search_configs', 'verboseLogging', 'INTEGER DEFAULT 0');
          _logger.db('DB migrated to v18 (biometric lock)');
        }
        if (oldVersion < 19) {
          // v1.7.25：思考相关改为每对话独有 → conversations 补 3 列
          await _ensureColumn(db, 'conversations', 'reactEnabled', 'INTEGER DEFAULT 1');
          await _ensureColumn(db, 'conversations', 'reasoningEffort', 'INTEGER DEFAULT 0');
          await _ensureColumn(db, 'conversations', 'reactAutoMode', 'INTEGER DEFAULT 1');
          await _ensureColumn(db, 'conversations', 'reactMaxRounds', 'INTEGER DEFAULT 30');
          _logger.db('DB migrated to v19 (per-conversation reasoning effort)');
        }
        if (oldVersion < 20) {
          // v1.7.26 (C2)：messages 补 token 用量 3 列（此前仅内存，重启后丢失）
          await _ensureColumn(db, 'messages', 'promptTokens', 'INTEGER');
          await _ensureColumn(db, 'messages', 'completionTokens', 'INTEGER');
          await _ensureColumn(db, 'messages', 'totalTokens', 'INTEGER');
          _logger.db('DB migrated to v20 (token usage persistence)');
        }
        if (oldVersion < 21) {
          // v1.7.26 (E3)：重试版本快照持久化——新建 message_versions 表
          // （此前版本快照仅存进程内存，重启后版本切换功能丢失）
          await db.execute('''
            CREATE TABLE IF NOT EXISTS message_versions (
              retryOfId TEXT NOT NULL,
              versionIndex INTEGER NOT NULL,
              content TEXT NOT NULL,
              reasoningSteps TEXT DEFAULT '[]',
              promptTokens INTEGER,
              completionTokens INTEGER,
              totalTokens INTEGER,
              injectedWebSearchCount INTEGER DEFAULT 0,
              showStaleFootnote INTEGER DEFAULT 0,
              modelName TEXT DEFAULT '',
              savedAt TEXT NOT NULL,
              PRIMARY KEY (retryOfId, versionIndex)
            )
          ''');
          _logger.db('DB migrated to v21 (retry version snapshot persistence)');
        }
        if (oldVersion < 22) {
          // v1.7.33：api_configs 补 supportVision（视觉支持开关）——此前该字段只在
          // 模型类里存在，CREATE TABLE 漏列 + onUpgrade 未补，落库时 INSERT 静默失败
          // （与 v1.3.4 web_search_configs 同型踩坑）
          await _ensureColumn(db, 'api_configs', 'supportVision', 'INTEGER DEFAULT 1');
          _logger.db('DB migrated to v22 (per-config vision support toggle)');
        }
        if (oldVersion < 23) {
          // v1.7.34：跨对话记忆 + 深度研究 + 子代理编排
          //   summary         —— 后台 completeChat 生成的对话摘要（≤500 字）
          //   memoryEnabled   —— 跨对话记忆总开关（默认开，可在对话设置里关）
          //   deepResearchMode—— 深度研究模式（打开时强制多专家混合 + 更高轮数 + 关闭 20s 自检）
          //   subagentMode    —— 子代理路由模式：auto/main_only/force_search/force_synthesis/force_plugin
          await _ensureColumn(db, 'conversations', 'summary', "TEXT DEFAULT ''");
          await _ensureColumn(db, 'conversations', 'memoryEnabled', 'INTEGER DEFAULT 1');
          await _ensureColumn(db, 'conversations', 'deepResearchMode', 'INTEGER DEFAULT 0');
          await _ensureColumn(db, 'conversations', 'subagentMode', "TEXT DEFAULT 'auto'");
          _logger.db('DB migrated to v23 (cross-conversation memory + subagent orchestration)');
        }
      },
    );
    // 启动时 PRAGMA 自检：对 conversations / messages / web_search_configs / api_configs / plugins
    // 查 PRAGMA table_info 补缺失列 → 防御"CREATE TABLE 漏列 + onUpgrade 走不到"双向漏写问题
    // （踩坑 #43：新用户重装 onCreate schema 漏 contextAuto/autoCompress 导致 INSERT 失败）
    // v1.7.1 fix m6: 补充 plugins 表自检
    final db = _db!;
    await _ensureColumn(db, 'conversations', 'contextAuto',
        'INTEGER DEFAULT 1');
    await _ensureColumn(db, 'conversations', 'autoCompress',
        'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'messages', 'attachments', "TEXT DEFAULT '[]'");
    await _ensureColumn(db, 'api_configs', 'cachedModels',
        "TEXT DEFAULT ''");
    // plugins 表在 v9 新增，确保关键字段存在
    await _ensureColumn(db, 'plugins', 'id', "TEXT PRIMARY KEY");
    await _ensureColumn(db, 'plugins', 'enabled', 'INTEGER DEFAULT 1');
    // v1.7.9 (C1 修复)：web_search_configs 补 v10 安全审查 5 列
    // （此前 version 停在 9 → v10 迁移从未触发，新装/老用户都缺列 → 保存报
    //  "no column named skillspectorEndpoint" 静默失败；此处 ensureColumn 兜底）
    await _ensureColumn(db, 'web_search_configs', 'skillspectorEndpoint', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'web_search_configs', 'enableSkillSecurityScan', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'web_search_configs', 'enableMcpSecurityScan', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'web_search_configs', 'mobsfEndpoint', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'web_search_configs', 'enableApkSecurityScan', 'INTEGER DEFAULT 0');
    // v1.7.10：本地安全扫描 2 列
    await _ensureColumn(db, 'web_search_configs', 'enableLocalScan', 'INTEGER DEFAULT 1');
    await _ensureColumn(db, 'web_search_configs', 'localScanRulesUrl', "TEXT DEFAULT ''");
    // v1.7.11：VirusTotal + MobSF API Key
    await _ensureColumn(db, 'web_search_configs', 'virusTotalApiKey', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'web_search_configs', 'enableVirusTotalScan', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'web_search_configs', 'mobsfApiKey', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'messages', 'modelName', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'conversations', 'isPinned', 'INTEGER DEFAULT 0');
    // v1.7.25：per-conversation 思考字段（reasoningEffort/reactAutoMode/reactMaxRounds）
    await _ensureColumn(db, 'conversations', 'reactEnabled', 'INTEGER DEFAULT 1');
    await _ensureColumn(db, 'conversations', 'reasoningEffort', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'conversations', 'reactAutoMode', 'INTEGER DEFAULT 1');
    await _ensureColumn(db, 'conversations', 'reactMaxRounds', 'INTEGER DEFAULT 30');
    await _ensureColumn(db, 'api_configs', 'templateId', "TEXT DEFAULT 'custom'");
    // v1.7.33：api_configs 补 supportVision（视觉支持开关；关闭时图片附件走本机 OCR 降级）
    await _ensureColumn(db, 'api_configs', 'supportVision', 'INTEGER DEFAULT 1');
    // v1.7.34：conversations 补跨对话记忆 + 深度研究 + 子代理编排字段（双保险：onUpgrade + 启动自检）
    await _ensureColumn(db, 'conversations', 'summary', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'conversations', 'memoryEnabled', 'INTEGER DEFAULT 1');
    await _ensureColumn(db, 'conversations', 'deepResearchMode', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'conversations', 'subagentMode', "TEXT DEFAULT 'auto'");
    await _ensureColumn(db, 'messages', 'retryOf', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'messages', 'retryIndex', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'messages', 'reasoningSteps', "TEXT DEFAULT '[]'");
    await _ensureColumn(db, 'web_search_configs', 'biometricLockEnabled', 'INTEGER DEFAULT 0');
    // v1.7.26 (C2)：启动自检补 messages token 用量 3 列（双保险：onCreate schema + onUpgrade 链路）
    await _ensureColumn(db, 'messages', 'promptTokens', 'INTEGER');
    await _ensureColumn(db, 'messages', 'completionTokens', 'INTEGER');
    await _ensureColumn(db, 'messages', 'totalTokens', 'INTEGER');
    // v1.7.26 (E3)：启动自检补 message_versions 表（幂等，防 onCreate/onUpgrade 漏建）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_versions (
        retryOfId TEXT NOT NULL,
        versionIndex INTEGER NOT NULL,
        content TEXT NOT NULL,
        reasoningSteps TEXT DEFAULT '[]',
        promptTokens INTEGER,
        completionTokens INTEGER,
        totalTokens INTEGER,
        injectedWebSearchCount INTEGER DEFAULT 0,
        showStaleFootnote INTEGER DEFAULT 0,
        modelName TEXT DEFAULT '',
        savedAt TEXT NOT NULL,
        PRIMARY KEY (retryOfId, versionIndex)
      )
    ''');
    _initialized = true;
    _logger.db('DB initialized at $path (v21)');
  }

  /// PRAGMA 自检并补齐缺失列（SQLite 安全 ADD COLUMN）。
  /// 解决 onCreate / onUpgrade 任一链路漏写列时的 INSERT 崩溃。
  Future<void> _ensureColumn(Database db, String table, String column,
      String definition) async {
    try {
      final rows = await db.rawQuery('PRAGMA table_info($table)');
      final names = rows.map((r) => r['name'] as String).toSet();
      if (!names.contains(column)) {
        await db.execute(
            'ALTER TABLE $table ADD COLUMN $column $definition');
        _logger.db('ALTER TABLE $table ADD $column $definition');
      }
    } catch (e) {
      _logger.dbWarn('ensureColumn $table.$column failed: $e');
    }
  }

  Future<void> _createV1Tables(Database db) async {
    await db.execute('''
      CREATE TABLE api_configs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        baseUrl TEXT NOT NULL,
        apiKey TEXT NOT NULL,
        model TEXT NOT NULL,
        systemPrompt TEXT DEFAULT '',
        temperature REAL DEFAULT 0.7,
        topP REAL DEFAULT 1.0,
        maxTokens INTEGER DEFAULT 2048,
        templateId TEXT DEFAULT 'custom',
        cachedModels TEXT DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        apiConfigId TEXT NOT NULL,
        lastMessage TEXT,
        contextLimit INTEGER DEFAULT 20,
        temperature REAL DEFAULT 0.7,
        topP REAL DEFAULT 1.0,
        enable20sCheck INTEGER DEFAULT 1,
        contextAuto INTEGER DEFAULT 1,
        autoCompress INTEGER DEFAULT 0,
        isPinned INTEGER DEFAULT 0,
        updatedAt TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        FOREIGN KEY (apiConfigId) REFERENCES api_configs (id)
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversationId TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        attachments TEXT DEFAULT '[]',
        modelName TEXT DEFAULT '',
        retryOf TEXT DEFAULT '',
        retryIndex INTEGER DEFAULT 0,
        reasoningSteps TEXT DEFAULT '[]',
        promptTokens INTEGER,
        completionTokens INTEGER,
        totalTokens INTEGER,
        FOREIGN KEY (conversationId) REFERENCES conversations (id) ON DELETE CASCADE
      )
    ''');
  }

  /// v1.3.6：为旧库 messages 表补 attachments 列
  /// 不加这列 → 带附件的消息保存时 SQLite 报 "no column named attachments"，
  /// 附件静默丢失（同 v1.3.4 web_search_configs 那次踩的坑）
  Future<void> _migrateV4MessagesAttachments(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(messages)');
    final names = cols.map((c) => c['name'] as String).toSet();
    if (!names.contains('attachments')) {
      await db.execute(
          "ALTER TABLE messages ADD COLUMN attachments TEXT DEFAULT '[]'");
      _logger.db('ALTER TABLE messages ADD attachments');
    }
  }

  /// v1.3.9：为旧库 web_search_configs 补 5 个新搜索服务商字段
  /// 不加 → 选 SerpAPI/Brave/Google CSE/DuckDuckGo(无须 key 但 enum 新增) 后
  /// 保存报 "no column named serpApiKey" → 🌐 按钮/设置保存全部静默失败
  /// （铁律 #7：新增字段必须同步 CREATE TABLE + ALTER TABLE + bump version）
  Future<void> _migrateV5WebSearchColumns(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(web_search_configs)');
    final existingCols = rows.map((r) => r['name'] as String).toSet();
    const defs = <String, String>{
      'serpApiKey': "TEXT DEFAULT ''",
      'serpapiEngine': "TEXT DEFAULT 'google'",
      'braveApiKey': "TEXT DEFAULT ''",
      'googleCseApiKey': "TEXT DEFAULT ''",
      'googleCseId': "TEXT DEFAULT ''",
    };
    for (final entry in defs.entries) {
      if (!existingCols.contains(entry.key)) {
        await db.execute(
            'ALTER TABLE web_search_configs ADD COLUMN ${entry.key} ${entry.value}');
        _logger.db('ALTER TABLE web_search_configs ADD ${entry.key}');
      }
    }
  }

  Future<void> _createV2Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS web_search_configs (
        id TEXT PRIMARY KEY,
        webSearchEnabled INTEGER DEFAULT 1,
        provider TEXT DEFAULT 'bing',
        tavilyApiKey TEXT DEFAULT '',
        tavilySearchDepth TEXT DEFAULT 'basic',
        tavilyMaxResults INTEGER DEFAULT 5,
        searxngInstanceUrl TEXT DEFAULT '',
        maxSnippetCharsPerResult INTEGER DEFAULT 400,
        maxResultsInject INTEGER DEFAULT 5,
        persistentWebSearchToggle INTEGER DEFAULT 1,
        reactEnabled INTEGER DEFAULT 1,
        reactMaxRounds INTEGER DEFAULT 3,
        reactAutoMode INTEGER DEFAULT 0,
        githubProxyUrl TEXT DEFAULT '',
        verboseLogging INTEGER DEFAULT 0,
        serpApiKey TEXT DEFAULT '',
        serpapiEngine TEXT DEFAULT 'google',
        braveApiKey TEXT DEFAULT '',
        googleCseApiKey TEXT DEFAULT '',
        googleCseId TEXT DEFAULT '',
        skillspectorEndpoint TEXT DEFAULT '',
        enableSkillSecurityScan INTEGER DEFAULT 0,
        enableMcpSecurityScan INTEGER DEFAULT 0,
        mobsfEndpoint TEXT DEFAULT '',
        enableApkSecurityScan INTEGER DEFAULT 0,
        enableLocalScan INTEGER DEFAULT 1,
        localScanRulesUrl TEXT DEFAULT '',
        virusTotalApiKey TEXT DEFAULT '',
        enableVirusTotalScan INTEGER DEFAULT 0,
        mobsfApiKey TEXT DEFAULT '',
        biometricLockEnabled INTEGER DEFAULT 0
      )
    ''');
    final existing = await db
        .query('web_search_configs', where: 'id = ?', whereArgs: ['singleton']);
    if (existing.isEmpty) {
      final defaults = WebSearchConfig().toMap();
      await db.insert('web_search_configs', defaults);
      _logger.db('Default web_search_config inserted');
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS plugins (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        source TEXT NOT NULL,
        author TEXT,
        description TEXT,
        enabled INTEGER NOT NULL DEFAULT 1,
        installedAt INTEGER NOT NULL,
        metadataJson TEXT
      )
    ''');
    // v1.7.26 (E3)：重试版本快照持久化表（onCreate 路径——与 onUpgrade v21、
    // 启动自检三路同步，遵循"CREATE TABLE 三路同步"铁律）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_versions (
        retryOfId TEXT NOT NULL,
        versionIndex INTEGER NOT NULL,
        content TEXT NOT NULL,
        reasoningSteps TEXT DEFAULT '[]',
        promptTokens INTEGER,
        completionTokens INTEGER,
        totalTokens INTEGER,
        injectedWebSearchCount INTEGER DEFAULT 0,
        showStaleFootnote INTEGER DEFAULT 0,
        modelName TEXT DEFAULT '',
        savedAt TEXT NOT NULL,
        PRIMARY KEY (retryOfId, versionIndex)
      )
    ''');
  }

  /// v1.3.4：为已有数据库（v2 升级到 v3）补 web_search_configs 表缺失的列
  /// 原始 CREATE TABLE 遗漏了 v1.3.1~v1.3.4 新增的字段，导致保存时 SQLite 报
  /// "table has no column named XXX" → 🌐/🧠 按钮、设置保存、详细日志全部失效
  Future<void> _migrateV3WebSearchColumns(Database db) async {
    final columns = <String>[
      'persistentWebSearchToggle',
      'reactEnabled',
      'reactMaxRounds',
      'reactAutoMode',
      'githubProxyUrl',
      'verboseLogging'
    ];
    // PRAGMA table_info 返回已有列名，避免 ALTER TABLE 添加已存在的列报错
    final rows = await db.rawQuery('PRAGMA table_info(web_search_configs)');
    final existingCols = rows.map((r) => r['name'] as String).toSet();
    final defs = <String, String>{
      'persistentWebSearchToggle': 'INTEGER DEFAULT 1',
      'reactEnabled': 'INTEGER DEFAULT 1',
      'reactMaxRounds': 'INTEGER DEFAULT 3',
      'reactAutoMode': 'INTEGER DEFAULT 0',
      'githubProxyUrl': "TEXT DEFAULT ''",
      'verboseLogging': 'INTEGER DEFAULT 0',
    };
    for (final col in columns) {
      if (!existingCols.contains(col)) {
        await db.execute(
            'ALTER TABLE web_search_configs ADD COLUMN $col ${defs[col]}');
        _logger.db('ALTER TABLE web_search_configs ADD $col (v3 migration)');
      }
    }
  }

  Future<void> _migrateV6ConversationSettings(Database db) async {
    final apiRows = await db.rawQuery('PRAGMA table_info(api_configs)');
    final apiCols = apiRows.map((r) => r['name'] as String).toSet();
    if (!apiCols.contains('topP')) {
      await db.execute('ALTER TABLE api_configs ADD COLUMN topP REAL DEFAULT 1.0');
    }

    final conversationRows =
        await db.rawQuery('PRAGMA table_info(conversations)');
    final conversationCols =
        conversationRows.map((r) => r['name'] as String).toSet();
    const defs = <String, String>{
      'contextLimit': 'INTEGER DEFAULT 20',
      'temperature': 'REAL DEFAULT 0.7',
      'topP': 'REAL DEFAULT 1.0',
      'enable20sCheck': 'INTEGER DEFAULT 1',
    };
    for (final entry in defs.entries) {
      if (!conversationCols.contains(entry.key)) {
        await db.execute(
            'ALTER TABLE conversations ADD COLUMN ${entry.key} ${entry.value}');
      }
    }
  }

  /// v1.4.1：为旧库 conversations 补 contextAuto / autoCompress 两列
  /// contextAuto=1（默认）→ 上下文"自动"模式（不截断）；=0 → 细化手动上限
  /// autoCompress=1 → 上下文过长时自动把旧消息压成摘要
  Future<void> _migrateV7ContextColumns(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(conversations)');
    final cols = rows.map((r) => r['name'] as String).toSet();
    const defs = <String, String>{
      'contextAuto': 'INTEGER DEFAULT 1',
      'autoCompress': 'INTEGER DEFAULT 0',
    };
    for (final entry in defs.entries) {
      if (!cols.contains(entry.key)) {
        await db.execute(
            'ALTER TABLE conversations ADD COLUMN ${entry.key} ${entry.value}');
        _logger.db('ALTER TABLE conversations ADD ${entry.key} (v6 migration)');
      }
    }
  }

  /// v1.5.0：api_configs 补 cachedModels TEXT 列（缓存 GET /v1/models 返回的模型 id 列表）
  ///
  /// 老用户升级走这里；新用户走 _createV1Tables 的 CREATE TABLE。
  /// 教训#43：CREATE TABLE 和 ALTER TABLE 两路必须同步写。
  /// 启动时还有 _ensureColumn 兜底（防 onUpgrade 链路漏写）。
  Future<void> _migrateV8CachedModels(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(api_configs)');
    final cols = rows.map((r) => r['name'] as String).toSet();
    if (!cols.contains('cachedModels')) {
      await db.execute(
          "ALTER TABLE api_configs ADD COLUMN cachedModels TEXT DEFAULT ''");
      _logger.db('ALTER TABLE api_configs ADD cachedModels (v8 migration)');
    }
  }

  Future<void> _migrateV9Plugins(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(plugins)');
    if (rows.isEmpty) {
      await db.execute('''
        CREATE TABLE plugins (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          version TEXT NOT NULL,
          source TEXT NOT NULL,
          author TEXT,
          description TEXT,
          enabled INTEGER NOT NULL DEFAULT 1,
          installedAt INTEGER NOT NULL,
          metadataJson TEXT
        )
      ''');
      _logger.db('CREATE TABLE plugins (v9 migration)');
    } else {
      final cols = rows.map((r) => r['name'] as String).toSet();
      // v1.7.1 fix C5: SQLite 不支持 ALTER TABLE 添加 PRIMARY KEY 列
      // id 列必须在 CREATE TABLE 时定义，不能通过 ALTER TABLE 添加
      const defs = <String, String>{
        'name': 'TEXT NOT NULL',
        'version': 'TEXT NOT NULL',
        'source': 'TEXT NOT NULL',
        'author': 'TEXT',
        'description': 'TEXT',
        'enabled': 'INTEGER NOT NULL DEFAULT 1',
        'installedAt': 'INTEGER NOT NULL',
        'metadataJson': 'TEXT',
      };
      for (final entry in defs.entries) {
        if (!cols.contains(entry.key)) {
          try {
            await db.execute(
                'ALTER TABLE plugins ADD COLUMN ${entry.key} ${entry.value}');
            _logger.db('ALTER TABLE plugins ADD ${entry.key} (v9 migration)');
          } catch (_) {}
        }
      }
    }
  }

  /// v1.7.5：web_search_configs 补安全审查相关字段
  Future<void> _migrateV10SecurityScan(Database db) async {
    final rows = await db.rawQuery('PRAGMA table_info(web_search_configs)');
    final existingCols = rows.map((r) => r['name'] as String).toSet();
    const defs = <String, String>{
      'skillspectorEndpoint': "TEXT DEFAULT ''",
      'enableSkillSecurityScan': 'INTEGER DEFAULT 0',
      'enableMcpSecurityScan': 'INTEGER DEFAULT 0',
      'mobsfEndpoint': "TEXT DEFAULT ''",
      'enableApkSecurityScan': 'INTEGER DEFAULT 0',
    };
    for (final entry in defs.entries) {
      if (!existingCols.contains(entry.key)) {
        await db.execute(
            'ALTER TABLE web_search_configs ADD COLUMN ${entry.key} ${entry.value}');
        _logger.db('ALTER TABLE web_search_configs ADD ${entry.key} (v10 migration)');
      }
    }
  }

  Future<Database> get db async {
    if (_db == null) await init();
    return _db!;
  }

  // --- API Configs ---
  Future<List<ApiConfig>> getApiConfigs() async {
    final database = await db;
    final maps = await database.query('api_configs', orderBy: 'name');
    return maps.map((m) => ApiConfig.fromMap(m)).toList();
  }

  Future<ApiConfig?> getApiConfig(String id) async {
    final database = await db;
    final maps =
        await database.query('api_configs', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return ApiConfig.fromMap(maps.first);
  }

  Future<String> saveApiConfig(ApiConfig config) async {
    final database = await db;
    await database.insert('api_configs', config.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _logger.db('API config saved: ${config.id} (${config.name})');
    notifyListeners();
    return config.id;
  }

  Future<void> deleteApiConfig(String id) async {
    final database = await db;
    // Delete related conversations and messages
    final convs = await database
        .query('conversations', where: 'apiConfigId = ?', whereArgs: [id]);
    for (final conv in convs) {
      await database.delete('messages',
          where: 'conversationId = ?', whereArgs: [conv['id']]);
    }
    await database
        .delete('conversations', where: 'apiConfigId = ?', whereArgs: [id]);
    await database.delete('api_configs', where: 'id = ?', whereArgs: [id]);
    _logger.db('API config deleted: $id (cascaded messages/conversations)');
    notifyListeners();
  }

  // --- Web Search Config (singleton) ---
  Future<WebSearchConfig> getWebSearchConfig() async {
    final database = await db;
    final maps = await database
        .query('web_search_configs', where: 'id = ?', whereArgs: ['singleton']);
    if (maps.isEmpty) return WebSearchConfig();
    return WebSearchConfig.fromMap(maps.first);
  }

  Future<void> saveWebSearchConfig(WebSearchConfig cfg) async {
    final database = await db;
    final map = cfg.toMap()..['id'] = 'singleton';
    await database.insert('web_search_configs', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
    _logger.db(
      'WebSearch config saved: provider=${cfg.provider.name}, '
      'enabled=${cfg.webSearchEnabled}, '
      'tavilyKey=${cfg.tavilyApiKey.isEmpty ? 'empty' : '***'}',
    );
    notifyListeners();
  }

  Future<bool> getBiometricLockEnabled() async {
    final cfg = await getWebSearchConfig();
    return cfg.biometricLockEnabled;
  }

  Future<void> setBiometricLockEnabled(bool enabled) async {
    final cfg = await getWebSearchConfig();
    cfg.biometricLockEnabled = enabled;
    await saveWebSearchConfig(cfg);
    _logger.app('Biometric lock ${enabled ? "enabled" : "disabled"}');
  }

  // --- Conversations ---
  Future<List<Conversation>> getConversations() async {
    final database = await db;
    final maps =
        await database.query('conversations', orderBy: 'isPinned DESC, updatedAt DESC');
    return maps.map((m) => Conversation.fromMap(m)).toList();
  }

  Future<Conversation?> getConversation(String id) async {
    final database = await db;
    final maps =
        await database.query('conversations', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Conversation.fromMap(maps.first);
  }

  Future<String> saveConversation(Conversation conv) async {
    final database = await db;
    await database.insert('conversations', conv.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
    return conv.id;
  }

  Future<void> updateConversationTitle(String id, String title) async {
    final database = await db;
    await database.update('conversations',
        {'title': title, 'updatedAt': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  /// v1.7.34：更新对话摘要（跨对话记忆；后台 completeChat 生成后写回，不刷 updatedAt 以免污染排序）
  Future<void> updateConversationSummary(String id, String summary) async {
    final database = await db;
    await database.update('conversations', {'summary': summary},
        where: 'id = ?', whereArgs: [id]);
  }

  /// v1.7.34：取最近 N 个有摘要的对话（不含当前对话 id）
  /// 用于消息发送前拼跨对话记忆 system prompt。
  /// 返回字段：id / title / summary / updatedAt（已按 updatedAt 倒序）
  Future<List<Map<String, dynamic>>> getRecentSummaries(
      int limit, {String? excludeId}) async {
    final database = await db;
    final whereArgs = excludeId == null
        ? <Object?>[]
        : <Object?>[excludeId];
    final where = excludeId == null ? null : 'id != ? AND summary != \'\'';
    final maps = await database.query(
      'conversations',
      where: where,
      whereArgs: whereArgs,
      columns: ['id', 'title', 'summary', 'updatedAt'],
      orderBy: 'updatedAt DESC',
      limit: excludeId == null ? limit : limit + 1,
    );
    // excludeId == null 时无需过滤空 summary；有 excludeId 时过滤 summary 为空的行
    return maps
        .where((m) => ((m['summary'] as String?) ?? '').isNotEmpty)
        .take(limit)
        .toList();
  }

  Future<void> togglePinConversation(String id, bool isPinned) async {
    final database = await db;
    await database.update('conversations',
        {'isPinned': isPinned ? 1 : 0, 'updatedAt': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
    final database = await db;
    await database
        .delete('messages', where: 'conversationId = ?', whereArgs: [id]);
    await database.delete('conversations', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  // --- Messages ---
  Future<List<ChatMessage>> getMessages(String conversationId) async {
    final database = await db;
    final maps = await database.query('messages',
        where: 'conversationId = ?',
        whereArgs: [conversationId],
        orderBy: 'createdAt ASC');
    return maps.map((m) => ChatMessage.fromMap(m)).toList();
  }

  Future<String> saveMessage(ChatMessage msg) async {
    final database = await db;
    // v1.7.16 修复：INSERT 消息 + UPDATE 会话列表分两步无事务，进程被杀会留下
    // "消息已存但 lastMessage/updatedAt 未更新"的不一致；用事务包裹保证原子性。
    await database.transaction((txn) async {
      await txn.insert('messages', msg.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      // Update conversation's lastMessage and updatedAt
      await txn.update(
          'conversations',
          {
            'lastMessage': msg.content.length > 50
                ? '${msg.content.substring(0, 50)}...'
                : msg.content,
            'updatedAt': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [msg.conversationId]);
    });
    notifyListeners();
    return msg.id;
  }

  Future<void> updateMessageContent(String id, String content) async {
    final database = await db;
    await database.update('messages', {'content': content},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMessage(String id) async {
    final database = await db;
    await database.delete('messages', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  // v1.7.26 (E5)：批量删除消息用单事务包裹（撤回级联删除一批消息时保证原子性）
  Future<void> deleteMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final database = await db;
    await database.transaction((txn) async {
      for (final id in ids) {
        await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      }
    });
    notifyListeners();
  }

  // v1.7.26 (E7)：清空会话消息时同步重置会话摘要与更新时间，
  // 避免"消息已删但会话列表仍显示旧 lastMessage/updatedAt"的不一致。
  Future<void> deleteMessagesByConversation(String conversationId) async {
    final database = await db;
    await database.transaction((txn) async {
      await txn.delete('messages',
          where: 'conversationId = ?', whereArgs: [conversationId]);
      await txn.update(
          'conversations',
          {'lastMessage': '', 'updatedAt': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [conversationId]);
    });
    notifyListeners();
  }

  // ===== v1.7.26 (E3)：重试版本快照持久化（message_versions 表） =====

  /// 保存/覆盖一条重试版本快照（versionIndex 与内存 store 一致，1-based；
  /// 同 retryOfId+versionIndex 幂等覆盖）
  Future<void> saveMessageVersion(
      String retryOfId, int versionIndex, RetryVersion v) async {
    final database = await db;
    await database.insert(
      'message_versions',
      {
        'retryOfId': retryOfId,
        'versionIndex': versionIndex,
        'content': v.content,
        'reasoningSteps': json
            .encode(v.reasoningSteps.map((s) => s.toMap()).toList()),
        if (v.promptTokens != null) 'promptTokens': v.promptTokens,
        if (v.completionTokens != null) 'completionTokens': v.completionTokens,
        if (v.totalTokens != null) 'totalTokens': v.totalTokens,
        'injectedWebSearchCount': v.injectedWebSearchCount,
        'showStaleFootnote': v.showStaleFootnote ? 1 : 0,
        'modelName': v.modelName,
        'savedAt': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 加载全部重试版本快照（按 retryOfId 分组、versionIndex 升序，
  /// 与进程内 _retryVersionStore 结构一致）
  Future<Map<String, List<RetryVersion>>> loadMessageVersions() async {
    final database = await db;
    final maps = await database
        .query('message_versions', orderBy: 'versionIndex ASC');
    final result = <String, List<RetryVersion>>{};
    for (final m in maps) {
      final retryOfId = m['retryOfId'] as String;
      final list = result.putIfAbsent(retryOfId, () => []);
      final reasoning = <ReasoningStep>[];
      final raw = m['reasoningSteps'] as String?;
      if (raw != null && raw.isNotEmpty && raw != '[]') {
        try {
          final decoded = json.decode(raw) as List;
          for (final item in decoded) {
            reasoning
                .add(ReasoningStep.fromMap(item as Map<String, dynamic>));
          }
        } catch (_) {}
      }
      list.add(RetryVersion(
        content: m['content'] as String,
        reasoningSteps: reasoning,
        promptTokens: m['promptTokens'] as int?,
        completionTokens: m['completionTokens'] as int?,
        totalTokens: m['totalTokens'] as int?,
        injectedWebSearchCount: (m['injectedWebSearchCount'] as int?) ?? 0,
        showStaleFootnote: ((m['showStaleFootnote'] as int?) ?? 0) != 0,
        modelName: (m['modelName'] as String?) ?? '',
      ));
    }
    return result;
  }

  /// 撤回某条提问时清理其重试版本快照
  Future<void> deleteMessageVersions(String retryOfId) async {
    final database = await db;
    await database
        .delete('message_versions', where: 'retryOfId = ?', whereArgs: [retryOfId]);
  }

  Future<List<Map<String, dynamic>>> loadAllPlugins() async {
    final database = await db;
    return await database.query('plugins', orderBy: 'installedAt DESC');
  }

  Future<void> savePluginState(String id, {bool? enabled, String? metadataJson}) async {
    final database = await db;
    final values = <String, dynamic>{};
    if (enabled != null) {
      values['enabled'] = enabled ? 1 : 0;
    }
    if (metadataJson != null) {
      values['metadataJson'] = metadataJson;
    }
    if (values.isNotEmpty) {
      // v1.7.9 (M13 修复)：UPDATE 影响 0 行时兜底 INSERT
      // 系统插件（search/download/ask_user/self_check/answer）由 createBuiltinPluginRegistry
      // 只注册进内存、不写 plugins 表 → 旧逻辑 UPDATE 0 行 → 禁用状态重启后静默丢失
      final affected = await database
          .update('plugins', values, where: 'id = ?', whereArgs: [id]);
      if (affected == 0) {
        await database.insert(
          'plugins',
          {
            'id': id,
            'name': id,
            'version': '1.0.0',
            'source': 'system',
            'author': 'system',
            'description': 'built-in plugin state row',
            'enabled': values['enabled'] ?? 1,
            if (metadataJson != null) 'metadataJson': metadataJson,
            'installedAt': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      notifyListeners();
    }
  }

  Future<Map<String, bool>> loadPluginStates() async {
    final database = await db;
    final maps = await database.query('plugins', columns: ['id', 'enabled']);
    final result = <String, bool>{};
    for (final m in maps) {
      // v1.7.16 修复：未来 schema 变动导致列值为 null 时，非空强转会抛 CastError
      // 使插件启用状态全丢；改为带默认值的宽松读取。
      final id = m['id'] as String? ?? '';
      final enabled = (m['enabled'] as int? ?? 1) == 1;
      if (id.isNotEmpty) result[id] = enabled;
    }
    return result;
  }

  Future<void> upsertPlugin(Map<String, dynamic> row) async {
    final database = await db;
    await database.insert('plugins', row, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<void> deletePlugin(String id) async {
    final database = await db;
    await database.delete('plugins', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }
}
