import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../constants.dart' show kAppVersionConst;

// ============================================================================
// v1.4.2：全链路结构化日志分类
//
// 设计目标：**用户每一次按键/操作/网络请求/异常都有一条可筛选的日志**，
// 出现 bug 时不用猜，打开日志按分类过滤就能还原完整操作链路。
//
// 分类说明：
//   APP      — 应用生命周期（启动/前后台/版本初始化）
//   UI       — 用户界面操作（点击按钮/切换页面/对话框打开关闭）
//   NAV      — 页面路由导航（进入/离开页面）
//   DB       — 数据库读写/迁移/PRAGMA 自检
//   CHAT     — 对话生命周期（新建/删除/标题更新）
//   API      — LLM API 请求/响应（含耗时/状态码；密钥会被脱敏）
//   REACT    — ReAct 循环（thinking/search/ask_user/download/self_check 各阶段）
//   COMPRESS — 上下文压缩（手动/自动触发、token、摘要 token）
//   WS       — 联网搜索（web_search + 文件下载搜索）
//   DOWNLOAD — 下载任务（APK/视频/图片/文档等，含进度/成功/失败）
//   BACKUP   — 导入导出备份
//   CONFIG   — 设置/配置修改
//   ERROR    — 全局异常捕获、未处理 async error
//   PERF     — 性能相关（慢操作、build 耗时）
// ============================================================================
enum LogCat {
  app('APP'),
  ui('UI'),
  nav('NAV'),
  db('DB'),
  chat('CHAT'),
  api('API'),
  react('REACT'),
  compress('COMPRESS'),
  ws('WS'),
  download('DOWNLOAD'),
  backup('BACKUP'),
  config('CONFIG'),
  error('ERROR'),
  perf('PERF');

  final String key;
  const LogCat(this.key);

  /// 英文 key → 中文展示名（用于日志查看页筛选 chip）
  String get labelCN {
    switch (this) {
      case LogCat.app:      return '应用';
      case LogCat.ui:       return 'UI';
      case LogCat.nav:      return '导航';
      case LogCat.db:       return '数据库';
      case LogCat.chat:     return '聊天';
      case LogCat.api:      return 'API';
      case LogCat.react:    return 'ReAct';
      case LogCat.compress: return '压缩';
      case LogCat.ws:       return '搜索';
      case LogCat.download: return '下载';
      case LogCat.backup:   return '备份';
      case LogCat.config:   return '配置';
      case LogCat.error:    return '错误';
      case LogCat.perf:     return '性能';
    }
  }

  /// v1.6.6：英文界面下的展示名
  String get labelEN {
    switch (this) {
      case LogCat.app:      return 'App';
      case LogCat.ui:       return 'UI';
      case LogCat.nav:      return 'Nav';
      case LogCat.db:       return 'DB';
      case LogCat.chat:     return 'Chat';
      case LogCat.api:      return 'API';
      case LogCat.react:    return 'ReAct';
      case LogCat.compress: return 'Compress';
      case LogCat.ws:       return 'Search';
      case LogCat.download: return 'Download';
      case LogCat.backup:   return 'Backup';
      case LogCat.config:   return 'Config';
      case LogCat.error:    return 'Error';
      case LogCat.perf:     return 'Perf';
    }
  }

  /// 颜色标记（ANSI 16 色级别；这里仅用于 UI 渲染查表，不直接写文件）
  int get colorSeedHash => key.hashCode;
}

/// 应用运行日志服务（单例，v1.4.2 全链路结构化）
///
/// - 内存里留最近 [maxMemoryLines] 行，UI 可以直接读
/// - 同时追加写到本地文件 `app_logs/aichat_<date>.log`，每天一个文件
/// - 单个日志文件超过 [maxFileBytes] 自动滚动到 `aichat_<date>.1.log`
/// - 提供"导出全部 / 打开 / 清空"接口，方便用户把日志发给我看
/// - 新增 **分类便捷方法**：`ui()`, `nav()`, `db()`, `chat()`, `react()`,
///   `compress()`, `download()`, `backup()`, `config()` 等，让业务代码写日志像英语句子
/// - **敏感信息永远不记**：Authorization/Bearer/sk-*/apiKey/TVLY 等会自动脱敏
class LoggerService extends ChangeNotifier {
  LoggerService._internal();
  static final LoggerService instance = LoggerService._internal();

  static const int maxMemoryLines = 5000; // v1.4.2 扩容量：分类增多后 5000 条更稳妥
  static const int maxFileBytes = 2 * 1024 * 1024; // 2 MB / 文件
  static const int maxKeptDays = 7;

  final List<String> _buffer = [];
  List<String> get buffer => List.unmodifiable(_buffer);

  /// v1.4.2：按分类的内存缓冲副本（用于日志查看页分类筛选）
  final Map<LogCat, List<String>> _byCat = {
    for (final c in LogCat.values) c: [],
  };
  List<String> linesByCat(LogCat c) => List.unmodifiable(_byCat[c] ?? const []);

  Directory? _logDir;
  bool _initialized = false;

  /// v1.3.4：详细日志模式开关
  bool _verboseEnabled = false;
  bool get verboseEnabled => _verboseEnabled;
  set verboseEnabled(bool v) {
    _verboseEnabled = v;
    app('Verbose logging ${v ? "ENABLED" : "disabled"} (聊天内容/搜索结果将${v ? "会" : "不会"}被记录)');
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _logDir = Directory(p.join(appDir.path, 'app_logs'));
      if (!_logDir!.existsSync()) {
        await _logDir!.create(recursive: true);
      }
      _initialized = true;
      app('LoggerService initialized at ${_logDir!.path} (maxMemoryLines=$maxMemoryLines, verbose=$_verboseEnabled)');
      _purgeOldLogs();
    } catch (e, st) {
      debugPrint('LoggerService init failed: $e\n$st');
    }
  }

  // ---------- 通用级别方法（向后兼容） ----------
  void debug(String msg, {LogCat? cat, String? tag}) => _write('DEBUG', msg, cat: cat, tag: tag);
  void info(String msg,  {LogCat? cat, String? tag}) => _write('INFO',  msg, cat: cat, tag: tag);
  void warn(String msg,  {LogCat? cat, String? tag}) => _write('WARN',  msg, cat: cat, tag: tag);
  void error(String msg, {Object? error, StackTrace? stack, LogCat? cat, String? tag}) {
    final buf = StringBuffer(msg);
    if (error != null) buf.write('\n  ↳ error: $error');
    if (stack != null) {
      buf.write('\n  ↳ stack:\n${stack.toString().split('\n').take(8).join('\n')}');
    }
    _write('ERROR', buf.toString(), cat: cat ?? LogCat.error, tag: tag);
  }

  /// 详细日志 — 只在 verboseEnabled=true 时写入
  /// 用于记录聊天内容、搜索结果详情、AI 思考全文等敏感信息（找问题用）
  void verbose(String msg, {LogCat? cat, String? tag}) {
    if (!_verboseEnabled) return;
    _write('VERBOSE', msg, cat: cat, tag: tag);
  }

  // ---------- 分类便捷方法（v1.4.2 新增） ----------
  // 写日志就像写英语句子：logger.ui('新建聊天按钮被点击'), logger.db('saveConversation succeed id=xxx')
  void app(String m)        => info(m, cat: LogCat.app);
  void ui(String m)         => info(m, cat: LogCat.ui);
  void nav(String m)        => info(m, cat: LogCat.nav);
  void db(String m)         => info(m, cat: LogCat.db);
  void dbWarn(String m)     => warn(m, cat: LogCat.db);
  void chat(String m)       => info(m, cat: LogCat.chat);
  void api(String m)        => info(m, cat: LogCat.api);
  void react(String m)      => info(m, cat: LogCat.react);
  void compress(String m)   => info(m, cat: LogCat.compress);
  void ws(String m)         => info(m, cat: LogCat.ws);
  void download(String m)   => info(m, cat: LogCat.download);
  void backup(String m)     => info(m, cat: LogCat.backup);
  void config(String m)     => info(m, cat: LogCat.config);
  void perf(String m)       => info(m, cat: LogCat.perf);

  // 带 VERBOSE 级别的分类变体
  void vChat(String m)      => verbose(m, cat: LogCat.chat);
  void vReact(String m)     => verbose(m, cat: LogCat.react);
  void vWs(String m)        => verbose(m, cat: LogCat.ws);
  void vApi(String m)       => verbose(m, cat: LogCat.api);

  // ---------- 核心：写日志 ----------
  void _write(String level, String msg, {LogCat? cat, String? tag}) {
    final now = DateTime.now();
    final safeMsg = level == 'VERBOSE'
        ? _scrubSensitive(msg, truncate: false)
        : _scrubSensitive(msg);
    // 行格式：
    //   2026-08-20T18:12:48.488 [INFO][UI][新建聊天] 按钮被点击
    //   2026-08-20T18:12:49.001 [INFO][REACT] detected tag: <ask_user>
    final c = cat?.key ?? 'GEN';
    final lineParts = [
      now.toIso8601String(),
      '[$level]',
      '[$c]',
      if (tag != null) '[$tag]',
      safeMsg,
    ];
    final line = lineParts.join(' ');

    // 1) 内存缓冲（总量）
    _buffer.add(line);
    if (_buffer.length > maxMemoryLines) {
      _buffer.removeRange(0, _buffer.length - maxMemoryLines);
    }
    // 2) 按分类缓冲
    if (cat != null) {
      final bucket = _byCat[cat] ??= [];
      bucket.add(line);
      if (bucket.length > maxMemoryLines) {
        bucket.removeRange(0, bucket.length - maxMemoryLines);
      }
    }
    notifyListeners();

    // 3) 文件（fire-and-forget 异步 IO，不阻塞 UI；失败不抛）
    // v1.6.8 修复 Bug#11：原代码注释声称"异步"但实际用 *Sync 方法（existsSync/lengthSync/
    // deleteSync/renameSync/writeAsStringSync），每条日志都阻塞主线程做磁盘 IO。
    // 改为 fire-and-forget 调用异步方法，让 event loop 调度写入，不阻塞调用方。
    if (_initialized && _logDir != null) {
      unawaited(_writeFileAsync(line, now));
    }

    // 4) debugPrint 让 IDE 也能看到
    debugPrint(line);
  }

  /// 异步文件写入（v1.6.8 修复 Bug#11）：把同步 *Sync 调用全部改为 async/await，
  /// 让 event loop 调度，不阻塞调用方。
  Future<void> _writeFileAsync(String line, DateTime now) async {
    try {
      final date =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final file = File(p.join(_logDir!.path, 'nexus_$date.log'));
      if (await file.exists() && await file.length() > maxFileBytes) {
        final rolled = File('${file.path}.1');
        if (await rolled.exists()) await rolled.delete();
        await file.rename(rolled.path);
      }
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('Logger write failed: $e');
    }
  }

  /// 脱敏：移除/遮挡可能出现在日志里的敏感信息
  ///
  /// v1.4.2 扩展：
  ///   - 新增 `Authorization` 通用 Bearer 前缀（支持无引号/有引号/大写变体）
  ///   - 支持更广泛的 sk-* / xox* / gsk* 等 API Key 前缀
  ///   - 支持 `tavily-xxx` / `tvly-xxx` / `serp_xxx` / `brave-xxx` / `google_xxx` 等搜索 Key
  ///   - 对长 token 只保留前 4 后 4 位
  static String _scrubSensitive(String msg, {bool truncate = true}) {
    if (msg.isEmpty) return msg;
    String s = msg;

    // 1) Authorization: Bearer <token> （覆盖各种大小写/引号/空格）
    s = s.replaceAllMapped(
      RegExp(r'("?Authorization"?\s*:?\s*"?)\s*(Bearer|Basic)\s+([A-Za-z0-9\-_.=]+)',
          caseSensitive: false),
      (m) {
        final prefix = m.group(1)!;
        final scheme = m.group(2)!;
        final token = m.group(3)!;
        return '$prefix$scheme ${_maskToken(token)}';
      },
    );

    // 2) 通用 api_key / apikey / api-key 等
    s = s.replaceAllMapped(
      RegExp(r'("?api[_-]?key"?\s*[:=]\s*"?)([^\s&",\]\}\)]+)(?=[\s&",\]\}\)]|$)',
          caseSensitive: false),
      (m) => '${m.group(1)}***',
    );

    // 3) 常见云 / 开源 API Key 前缀（支持长 token 不截断）
    s = s.replaceAllMapped(
      RegExp(
          r'\b(sk|pk|rk|xox[baprs]|ghp|gho|ghu|ghr|glm|glmao|deepseek|ds|vllm|qwen|gsk|msk|ant|claude|apikey|ollama)-[A-Za-z0-9\-/.]{10,}\b',
          caseSensitive: false),
      (m) => _maskToken(m.group(0)!),
    );

    // 4) 搜索服务商 API Key
    s = s.replaceAllMapped(
      RegExp(r'\b(tvly|tavily|serpapi|serp|brave|google|bing)_?[A-Za-z0-9\-]{12,}\b',
          caseSensitive: false),
      (m) => '${m.group(1)}-***',
    );

    // 5) 通用长 Token（至少 24 字符的 base64-hex 混合串，带/不带前缀）
    s = s.replaceAllMapped(
      RegExp(r'\b([A-Za-z0-9_\-\.]{32,})\b'),
      (m) => _maskToken(m.group(1)!),
    );

    if (truncate && s.length > 500) {
      s = '${s.substring(0, 120)} ... [TRUNCATED ${s.length} chars] ... ${s.substring(s.length - 120)}';
    }
    return s;
  }

  /// 长 token 脱敏：保留前 4 后 4，中间用 *** 替换
  static String _maskToken(String token) {
    if (token.length <= 8) return '***';
    return '${token.substring(0, 4)}***${token.substring(token.length - 4)}';
  }

  // ---------- 测试可见桥（供 test/ 目录使用） ----------
  @visibleForTesting
  static String scrubForTest(String msg, {bool truncate = true}) =>
      _scrubSensitive(msg, truncate: truncate);

  @visibleForTesting
  static String maskForTest(String token) => _maskToken(token);

  // ---------- 公开脱敏（供自检等生产代码复用同一套逻辑） ----------
  /// 对一段文本做敏感信息脱敏，返回脱敏后的结果（自检服务用）。
  static String scrubSensitive(String msg, {bool truncate = true}) =>
      _scrubSensitive(msg, truncate: truncate);

  // ---------- UI / 导出 ----------
  /// 把所有现有日志（内存 + 全部日志文件）合并成一个字符串
  Future<String> exportAllText() async {
    final sb = StringBuffer();
    sb.writeln(
        '===== Nexus Log Export $kAppVersionConst ${DateTime.now().toIso8601String()} =====');
    sb.writeln(
        'Categories: ${LogCat.values.map((c) => c.key).join(', ')}');
    if (_logDir != null && _logDir!.existsSync()) {
      final files = _logDir!
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        sb.writeln('\n----- FILE: ${p.basename(f.path)} -----');
        try {
          sb.writeln(f.readAsStringSync());
        } catch (e) {
          sb.writeln('  (read failed: $e)');
        }
      }
    }
    sb.writeln(
        '\n----- IN-MEMORY BUFFER (latest ${_buffer.length} lines) -----');
    sb.writeln(_buffer.join('\n'));
    return sb.toString();
  }

  Future<String> exportToSingleFile() async {
    await init();
    final text = await exportAllText();
    final ts =
        DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final out = File(p.join(_logDir!.path, 'nexus_export_$ts.txt'));
    await out.writeAsString(text, flush: true);
    app('Log exported to ${out.path}');
    return out.path;
  }

  Future<String?> logDirPath() async {
    await init();
    return _logDir?.path;
  }

  Future<List<File>> listLogFiles() async {
    await init();
    if (_logDir == null) return [];
    return _logDir!
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log') || f.path.endsWith('.txt'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  Future<void> clearAll() async {
    _buffer.clear();
    for (final c in LogCat.values) {
      _byCat[c]?.clear();
    }
    if (_logDir != null && _logDir!.existsSync()) {
      for (final f in _logDir!.listSync().whereType<File>()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    notifyListeners();
    app('Logs cleared by user');
  }

  void _purgeOldLogs() {
    if (_logDir == null || !_logDir!.existsSync()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: maxKeptDays));
    for (final f in _logDir!.listSync().whereType<File>()) {
      try {
        final stat = f.statSync();
        if (stat.modified.isBefore(cutoff)) {
          f.deleteSync();
        }
      } catch (_) {}
    }
  }
}
