import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../models/conversation.dart';
import '../models/chat_message.dart';
import '../models/web_search_config.dart';
import '../services/storage_service.dart';
import '../services/api_service.dart';
import '../services/attachment_service.dart';
import '../services/web_search_service.dart';
import '../services/app_download_service.dart';
import '../services/logger_service.dart';
import '../services/react_parser.dart';
import '../services/security_scan_service.dart';
import '../plugins/plugin_registry.dart';
import '../plugins/plugin_context.dart';
import 'settings_screen.dart';
import 'plugin_management_screen.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_input.dart';
import '../widgets/app_source_selector.dart';

/// 聊天主界面（v1.3.0 大改版点）
///
/// 相比 v1.2.4 的变化：
/// - 增加 🌐 搜索按钮驱动的"消息发送前联网搜索"
/// - 当搜索模式关闭（searchMode=false）或搜索无结果时，**在回复消息顶部插入黄色警告条**："⚠️ 基于AI内置知识 — 可能已过时"
/// - APP 下载请求整合 AI 决策流程：
///     1. 先用 AI 识别意图（已用 detectDownloadIntent，无变化）
///     2. 若在内置目录 → 直接展示结果，但仍弹出"AI内置知识可能过时"的确认对话框
///     3. 不在内置目录 → 弹出"需要联网搜索，第三方链接需你确认"的提示
///     4. 若总开关关了 → 弹出"联网搜索已关闭，是否前往设置打开"
/// - 全程通过 LoggerService 写事件日志（严格不记聊天内容 / API Key）
class ChatScreen extends StatefulWidget {
  final Conversation conversation;

  const ChatScreen({super.key, required this.conversation});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _inputController = TextEditingController();
  final LoggerService _logger = LoggerService.instance;

  List<ChatMessage> _messages = [];
  ApiConfig? _apiConfig;
  List<ApiConfig> _apiConfigs = [];
  ApiConfig? _currentSessionModel;
  WebSearchConfig _webSearchCfg = WebSearchConfig();

  bool _isLoading = true;
  bool _isStreaming = false;

  /// v1.3.1 build 11：🌐 按钮状态改为"常驻"
  /// - 初始化读 persistentWebSearchToggle
  /// - 用户切换后立即持久化，不再"发完就重置为 false"
  bool _searchMode = false;

  // ===== v1.3.3 build 13 新增状态 =====
  /// 思考循环期间用户中途插话的消息队列（FIFO）
  /// _runReActLoop 每轮 LLM 返回后会 drain 这个队列到 workingMessages
  final List<String> _pendingFollowupMessages = [];
  int get pendingFollowupCount => _pendingFollowupMessages.length;

  /// 是否启用"每 20 秒确认一次"防卡壳机制（用户用 ⏱️ 按钮切换）
  bool _enable20sCheck = true;

  /// 用户在 20 秒确认弹窗里点了"终止输出" → ReAct 循环检测到后立即结束
  bool _reactLoopStopRequested = false;

  // ===== v1.4.5：AI 回复实时写入 DB（防崩溃丢失） =====
  /// 节流：上一次 assistant 内容写入 DB 的时间戳
  int _lastAssistantDbSaveMs = 0;

  /// 节流：上一次 assistant 内容写入 DB 时的 content 长度
  int _lastAssistantDbSaveLen = 0;

  /// 流式 / ReAct 过程中实时保存 assistant 消息内容到 DB（节流）。
  ///
  /// 触发条件（任一满足）：
  ///   - [force] = true（如：answer 首次落地、用户停止、出错后）
  ///   - 距上次保存 >= [minIntervalMs]（默认 2 秒）
  ///   - content 长度较上次新增 >= [minDeltaChars]（默认 300 字）
  ///
  /// 用 StorageService.updateMessageContent（只 UPDATE content 列），
  /// 避免 updateMessageContent 每帧触发 notifyListeners + conversation 表更新。
  /// 前提：[msg] 必须已通过 saveMessage INSERT 到 DB（id 已存在）。
  Future<void> _throttledSaveAssistantContent(
    StorageService storage,
    ChatMessage msg,
    String content, {
    bool force = false,
    int minIntervalMs = 2000,
    int minDeltaChars = 300,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final len = content.length;
    final byInterval = now - _lastAssistantDbSaveMs >= minIntervalMs;
    final byLength = len - _lastAssistantDbSaveLen >= minDeltaChars;
    if (!force && !byInterval && !byLength) return;

    try {
      await storage.updateMessageContent(msg.id, content);
      _lastAssistantDbSaveMs = now;
      _lastAssistantDbSaveLen = len;
    } catch (e, st) {
      _logger.error(
        '[Chat] _throttledSaveAssistantContent failed: $e',
        error: e,
        stack: st,
        cat: LogCat.chat,
        tag: 'Chat',
      );
    }
  }

  // ===== v1.3.6：📎 附件（待发送的附件，发送后挂到 userMsg 上）=====
  final AttachmentService _attachmentService = AttachmentService();
  final List<MessageAttachment> _pendingAttachments = [];

  // ===== v1.3.4 build 14 新增：监听设置页配置变化 =====
  /// ChatScreen 监听 StorageService 的 notifyListeners，
  /// 设置页保存配置（总开关/档位/代理/Tavily key 等）后，
  /// ChatScreen 立即重新加载 _webSearchCfg，刷新 🌐/🧠 按钮状态。
  /// 修复 v1.3.3 的 bug：设置页关总开关后，聊天页 🌐 按钮颜色不变。
  late final StorageService _storage;
  late final VoidCallback _storageListener;

  Future<void> _saveSearchToggle(bool value) async {
    final storage = context.read<StorageService>();
    final newCfg = _webSearchCfg.copyWith(persistentWebSearchToggle: value);
    await storage.saveWebSearchConfig(newCfg);
    if (mounted) {
      setState(() {
        _webSearchCfg = newCfg;
        _searchMode = value;
      });
    }
  }

  /// 保存 reactMaxRounds（设置里档位 + 聊天页长按细调都会调到这个）
  /// v1.3.3：clamp 上限放到 100（自动档可以调到很离谱）
  Future<void> _saveReactRounds(int rounds) async {
    final r = rounds.clamp(0, 100);
    final storage = context.read<StorageService>();
    // rounds=0 表示在聊天页临时关了，但不把全局 reactEnabled=false（保留设置里的主开关）
    // v1.3.3：手动调轮次时自动退出 autoMode（用户主动改了就不再"自动"）
    final newCfg =
        _webSearchCfg.copyWith(reactMaxRounds: r, reactAutoMode: false);
    await storage.saveWebSearchConfig(newCfg);
    if (mounted) setState(() => _webSearchCfg = newCfg);
  }

  /// v1.3.3 新增：保存"自动"档位状态
  /// autoMode=true 时同时把 reactMaxRounds 设为 30（自动档默认上限，可长按细调更高）
  Future<void> _saveReactAutoMode(bool autoMode) async {
    final storage = context.read<StorageService>();
    final newCfg = autoMode
        ? _webSearchCfg.copyWith(reactAutoMode: true, reactMaxRounds: 30)
        : _webSearchCfg.copyWith(reactAutoMode: false);
    await storage.saveWebSearchConfig(newCfg);
    if (mounted) setState(() => _webSearchCfg = newCfg);
  }

  /// 🧠 思考按钮左击：循环档位
  ///   v1.3.3 顺序：关(0) → 低(2) → 默认(3) → 中(5) → 高(8) → 自动(30) → 关(0)
  ///   "自动"档下 AI 自己决定搜索轮次，上限 30 轮，靠 20 秒确认机制兜底
  Future<void> _cycleReactLevel() async {
    // 用 reactAutoMode=true 表示"自动"档位
    // v1.3.4：删掉"默认"档，5 档精简为 关(0)→低(2)→中(5)→高(8)→自动→关
    final isAuto = _webSearchCfg.reactAutoMode;
    const seq = [0, 2, 5, 8];
    final cur = _webSearchCfg.reactMaxRounds;

    // 当前是"自动"档 → 下一档切回"关"
    if (isAuto) {
      await _saveReactRounds(0);
      if (mounted) {
        final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isZh
              ? '🧠 思考程度：关 (Off) （已停用思考循环）'
              : '🧠 Reasoning: Off (thinking loop disabled)'),
          duration: const Duration(seconds: 1, milliseconds: 200),
          behavior: SnackBarBehavior.floating,
          width: 240,
        ));
      }
      return;
    }

    // 当前不是"自动"档 → 在手动档位序列里循环，到"高"之后切到"自动"
    int idx = -1;
    for (int i = 0; i < seq.length; i++) {
      if (cur == seq[i]) {
        idx = i;
        break;
      }
    }
    if (idx == -1 && cur > 8) {
      // 超过"高"档（比如手动调到 12） → 视为已经在"高"之后，下一档切"自动"
      idx = seq.length - 1;
    } else if (idx == -1) {
      // 处于两档之间 → 找到下一个档位
      for (int i = 0; i < seq.length - 1; i++) {
        if (cur > seq[i] && cur < seq[i + 1]) {
          idx = i;
          break;
        }
      }
      if (idx == -1) idx = 0;
    }

    if (idx == seq.length - 1) {
      // 当前是"高" → 切到"自动"
      await _saveReactAutoMode(true);
      _logger.info('[Chat] 🧠 React level cycled: Auto (was High)',
          cat: LogCat.chat, tag: 'Chat');
    } else {
      // 切到下一个手动档
      final next = seq[idx + 1];
      await _saveReactRounds(next);
      final lvl = WebSearchConfig.estimateLevelLabel(next);
      _logger.info('[Chat] 🧠 React level cycled: rounds=$next label=$lvl',
          cat: LogCat.chat, tag: 'Chat');
    }
  }

  @override
  void initState() {
    super.initState();
    // v1.3.4：缓存 storage 引用 + 注册 listener，设置页改配置后能实时刷新
    _storage = context.read<StorageService>();
    _storageListener = _onStorageChanged;
    _storage.addListener(_storageListener);
    _loadData();
  }

  /// v1.3.4：StorageService.notifyListeners 触发 → 重新读 webSearchConfig 刷新 UI
  /// 修复 v1.3.3 bug：设置页关总开关后聊天页 🌐 按钮颜色不变
  /// v1.6.0：同时刷新 _apiConfigs / _apiConfig / _currentSessionModel
  void _onStorageChanged() {
    if (!mounted) return;
    // 用 postFrame 避免在 build 期间 setState
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final webCfg = await _storage.getWebSearchConfig();
      final allConfigs = await _storage.getApiConfigs();
      final config =
          await _storage.getApiConfig(widget.conversation.apiConfigId);
      if (!mounted) return;
      setState(() {
        _webSearchCfg = webCfg;
        _apiConfigs = allConfigs;
        _apiConfig = config;
        // _currentSessionModel 如果已经在 allConfigs 中就保留，否则重置
        if (_currentSessionModel != null &&
            !allConfigs.any((c) => c.id == _currentSessionModel!.id)) {
          _currentSessionModel =
              _apiConfig ?? (allConfigs.isNotEmpty ? allConfigs.first : null);
        }
        // _searchMode 保留用户当前选择；总开关关了 → active 自动算 false
      });
      // v1.3.4：同步详细日志模式到 LoggerService 单例
      if (LoggerService.instance.verboseEnabled != webCfg.verboseLogging) {
        LoggerService.instance.verboseEnabled = webCfg.verboseLogging;
      }
    });
  }

  Future<void> _loadData() async {
    final messages = await _storage.getMessages(widget.conversation.id);
    final config = await _storage.getApiConfig(widget.conversation.apiConfigId);
    final allConfigs = await _storage.getApiConfigs();
    final webCfg = await _storage.getWebSearchConfig();
    if (mounted) {
      setState(() {
        _messages = messages;
        _apiConfig = config;
        _apiConfigs = allConfigs;
        _currentSessionModel =
            _apiConfig ?? (allConfigs.isNotEmpty ? allConfigs.first : null);
        _webSearchCfg = webCfg;
        _enable20sCheck = widget.conversation.enable20sCheck;
        _searchMode = webCfg.persistentWebSearchToggle;
        _isLoading = false;
      });
      // v1.3.4：启动时同步详细日志模式
      LoggerService.instance.verboseEnabled = webCfg.verboseLogging;
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ==========================================================================
  // APP 下载意图处理（v1.3.2 重构版）
  //
  // 「AI + 联网 API」场景下，下载请求应该先走 _runReActLoop 让 AI：
  //     思考 → 查官网 → 出 <download intent= canonical keywords domains />
  // 然后下面这个方法拿到 (主关键词, 别名, 官方域名白名单) 后：
  //     1. 把用户消息入聊
  //     2. 内置目录 + GitHub + Tavily/Bing 并行搜（多关键词合并去重）
  //     3. 展示"已找到 N 个来源"气泡 + 来源面板（含信任徽章 + 二合一确认弹窗）
  //
  // 老流程（没配置 AI API 或 ReAct 关时）的 `_tryHandleDownloadIntent` 也会在
  // 做一次"LLM 判别或正则判别"之后，调用本方法做同样的 1+2+3。
  // ==========================================================================
  Future<void> _presentDownloadSources({
    required String userText, // 用户原始输入，需要先入聊
    required String keyword, // 主关键词（APP 标准名）
    required List<String> altKeywords, // 别名/增强搜索词
    required List<String> officialDomains, // LLM/预置给的官方域名白名单
    ChatMessage? existingUserMsg, // ReAct 场景已入聊 userMsg，传入避免重复
    ChatMessage? existingPlaceholder, // ReAct 场景已有的 assistantMsg 占位，传入替换其内容
    String platform =
        'android', // v1.6.9：android / pc，来自 ReAct <download platform=...>
  }) async {
    // v1.7.9 (M8 修复)：本方法由 ReAct dispatch 回调链调用，入口已处于 async gap，
    // 页面退出后 context.read/Localizations 会抛 deactivated widget 崩溃 → 入口先判 mounted
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final storage = context.read<StorageService>();
    final downloadSvc = context.read<AppDownloadService>();

    // 1) 用户消息写入聊天（如果还没写）
    ChatMessage userMsg = existingUserMsg ??
        ChatMessage.create(
          conversationId: widget.conversation.id,
          role: MessageRole.user,
          content: userText,
        );
    if (existingUserMsg == null) {
      await storage.saveMessage(userMsg);
      if (mounted) setState(() => _messages.add(userMsg));
    } else if (!_messages.contains(userMsg)) {
      if (mounted) setState(() => _messages.add(userMsg));
    }
    if (mounted) _scrollToBottom();

    // 2) 查内置目录：主 keyword + 别名一起去查（任一命中就算 inCatalog）
    final lookupKeywords = <String>{
      keyword,
      if (keyword.trim().isNotEmpty) keyword.trim(),
      ...altKeywords,
    };
    final catalogSources = <AppDownloadSource>[];
    final seen = <String>{};
    for (final k in lookupKeywords) {
      if (k.trim().isEmpty) continue;
      final rs = await downloadSvc.searchSources(k);
      for (final s in rs) {
        if (!seen.contains(s.downloadUrl)) {
          seen.add(s.downloadUrl);
          catalogSources.add(s);
        }
      }
    }
    final inCatalog = catalogSources.isNotEmpty;

    // 3) assistant 占位（如果 ReAct 没给占位，则新建）
    ChatMessage assistantMsg = existingPlaceholder ??
        ChatMessage.create(
          conversationId: widget.conversation.id,
          role: MessageRole.assistant,
          content: '🔎 ${l.tr('searchingApp')}',
        );
    if (existingPlaceholder == null) {
      await storage.saveMessage(assistantMsg);
      if (mounted) setState(() => _messages.add(assistantMsg));
      _scrollToBottom();
    } else {
      // ReAct 模式：把 thinking 后的占位文本显示为"搜索下载来源中…"
      assistantMsg.appendLastThinking(isZh
          ? '\n📦 解析完成，正在汇总下载来源…\n'
          : '\n📦 Parsed. Collecting download sources...\n');
      if (mounted) setState(() {});
    }

    // 4) 构造来源列表（内置 → GitHub → 联网），LLM 给的官方域名自动升级为 official
    final sources = <AppDownloadSource>[];
    final seenUrls = <String>{};
    void addAll(List<AppDownloadSource> list) {
      for (final s in list) {
        if (seenUrls.contains(s.downloadUrl)) continue;
        seenUrls.add(s.downloadUrl);
        var fixed = s;
        if (officialDomains.isNotEmpty) {
          try {
            final host = Uri.parse(s.downloadUrl).host.toLowerCase();
            for (final d in officialDomains) {
              final h = d.toLowerCase().trim();
              if (h.isEmpty) continue;
              if (host == h || host.endsWith('.$h')) {
                fixed = fixed.copyWithTrustLevel(SourceTrustLevel.official);
                break;
              }
            }
          } catch (_) {}
        }
        sources.add(fixed);
      }
    }

    addAll(catalogSources);

    final webQueryList = <String>[
      keyword,
      ...altKeywords,
    ].where((k) => k.trim().isNotEmpty).toList();
    // v1.6.9：根据 platform 决定搜索后缀（与原 ReAct if/else 行为一致）
    //   - platform=pc → 关键词加 "PC 客户端 / Windows / Mac"
    //   - platform=android → 关键词加 "安卓 / APK"
    final isPC = platform.toLowerCase() == 'pc';
    final suffixedWebQuery = <String>[];
    for (final k in webQueryList) {
      suffixedWebQuery.add(k);
      if (isPC) {
        suffixedWebQuery.add('$k PC 客户端');
        suffixedWebQuery.add('$k Windows 版');
      } else {
        suffixedWebQuery.add('$k 安卓');
        suffixedWebQuery.add('$k APK 官方');
      }
    }
    const maxGhReposPerKw = 2;
    final webEnabled = _webSearchCfg.webSearchEnabled;
    // v1.3.4：GitHub 代理加速（用户在设置里填的，留空=直连）
    final ghProxyUrl = _webSearchCfg.githubProxyUrl;
    if (webEnabled) {
      for (int i = 0; i < suffixedWebQuery.length; i++) {
        final q = suffixedWebQuery[i];
        try {
          final gh = await downloadSvc.searchGitHub(q,
              maxRepos: maxGhReposPerKw, proxyUrl: ghProxyUrl);
          addAll(gh);
        } catch (e) {
          _logger.warn('[Chat] GitHub search(q=$q) failed: $e',
              cat: LogCat.download, tag: 'DL');
        }
        try {
          final online = await downloadSvc.searchOnline(q, _webSearchCfg);
          addAll(online);
        } catch (e, st) {
          _logger.error('[Chat] Online search(q=$q) failed',
              error: e, stack: st, cat: LogCat.download, tag: 'DL');
        }
        if (sources.length >= 12) break;
      }
    }

    // 5) 写入结果 / 弹出面板
    if (!mounted) return;
    if (sources.isEmpty) {
      final replyText = webEnabled
          ? (isZh
              ? '😔 抱歉，联网搜索后未找到 **$keyword** 的可下载链接。\n\n'
                  '可能原因：\n'
                  '• 搜索引擎未返回有效直链\n'
                  '• 所有候选链接验证失败（403/404/超时）\n\n'
                  '建议：手动在浏览器访问官网下载。'
              : '😔 Sorry, no valid download links found for **$keyword** after web search.\n\n'
                  'Possible reasons:\n'
                  '• Search engine returned no direct links\n'
                  '• All candidates failed verification (403/404/timeout)\n\n'
                  'Tip: open the official site in a browser and download manually.')
          : (isZh
              ? '😔 联网搜索已关闭，且内置目录未收录 **$keyword**。\n'
                  '请在 设置 → 联网搜索 中打开总开关后重试。'
              : '😔 Web search is off and **$keyword** is not in the built-in catalog.\n'
                  'Enable the master switch in Settings → Web Search and retry.');
      // 复用 assistantMsg（更新而非新建）
      assistantMsg.content = replyText;
      assistantMsg.showStaleFootnote = true;
      await storage.saveMessage(assistantMsg);
      if (mounted) {
        setState(() {});
        _scrollToBottom();
      }
      _logger.warn(
          '[Chat] No sources found for $keyword (webEnabled=$webEnabled)',
          cat: LogCat.download,
          tag: 'DL');
      return;
    }

    final sb = StringBuffer();
    if (!inCatalog) {
      sb.writeln('ℹ️ ${l.tr('aiKnowledgeDisclaimer')}');
      sb.writeln('');
    } else {
      sb.writeln('⚠️ ${l.tr('aiKnowledgeWarningShort')}');
      sb.writeln('');
    }
    sb.writeln(isZh
        ? '✅ 找到 **${sources.length} 个** 下载来源：'
        : '✅ Found **${sources.length}** download source(s):');
    for (int i = 0; i < sources.length; i++) {
      final s = sources[i];
      final flag = switch (s.trustLevel) {
        SourceTrustLevel.official => '🟢',
        SourceTrustLevel.trustedThirdParty => '🟡',
        SourceTrustLevel.unknown => '🔴',
      };
      sb.writeln('$flag **${i + 1}. ${s.sourceName}**  (${s.sourceDomain})  \n'
          '   v${s.version}　·　${s.size}　·　${s.arch}\n');
    }
    sb.writeln(isZh
        ? '👇 请在下方弹出的面板中选择下载来源。'
        : '👇 Select a source from the panel below.');

    assistantMsg.content = sb.toString();
    assistantMsg.injectedWebSearchCount = 0; // 已有来源详情列出，不需额外 count 脚注
    assistantMsg.showStaleFootnote = !inCatalog && !webEnabled;
    await storage.saveMessage(assistantMsg);
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }
    _logger.info(
        '[Chat] Download intent: presenting ${sources.length} sources (keyword=$keyword)',
        cat: LogCat.download,
        tag: 'DL');

    AppSourceSelectorBottomSheet.show(
      // ignore: use_build_context_synchronously
      context,
      appName: keyword,
      sources: sources,
    );
  }

  // ==========================================================================
  // v1.4.2：通用文件下载来源面板（视频/图片/音频/文档等）
  // ==========================================================================

  Future<void> _presentFileDownloadSources({
    required String userText,
    required String query,
    required String fileType,
    ChatMessage? existingUserMsg,
    ChatMessage? existingPlaceholder,
  }) async {
    // v1.7.9 (M8 修复)：入口处于 async gap（ReAct 回调链），先判 mounted
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final storage = context.read<StorageService>();
    final downloadSvc = context.read<AppDownloadService>();

    // 1) 用户消息写入聊天（如果还没写）
    ChatMessage userMsg = existingUserMsg ??
        ChatMessage.create(
          conversationId: widget.conversation.id,
          role: MessageRole.user,
          content: userText,
        );
    if (existingUserMsg == null) {
      await storage.saveMessage(userMsg);
      if (mounted) setState(() => _messages.add(userMsg));
    } else if (!_messages.contains(userMsg)) {
      if (mounted) setState(() => _messages.add(userMsg));
    }
    if (mounted) _scrollToBottom();

    // 2) assistant 占位
    ChatMessage assistantMsg = existingPlaceholder ??
        ChatMessage.create(
          conversationId: widget.conversation.id,
          role: MessageRole.assistant,
          content: isZh
              ? '🔎 正在搜索可下载的$fileType文件…'
              : '🔎 Searching downloadable $fileType files...',
        );
    if (existingPlaceholder == null) {
      await storage.saveMessage(assistantMsg);
      if (mounted) setState(() => _messages.add(assistantMsg));
      _scrollToBottom();
    } else {
      assistantMsg.appendLastThinking(isZh
          ? '\n📦 $fileType文件搜索中…\n'
          : '\n📦 Searching $fileType files...\n');
      if (mounted) setState(() {});
    }

    // 3) 联网搜索文件直链
    final webEnabled = _webSearchCfg.webSearchEnabled;
    final sources = <Map<String, String>>[];

    if (webEnabled) {
      try {
        final found = await downloadSvc.searchFileDownloads(
          query,
          _webSearchCfg,
          fileType,
        );
        sources.addAll(found);
      } catch (e, st) {
        _logger.error('[Chat] File search failed',
            error: e, stack: st, cat: LogCat.download, tag: 'DL');
      }
    }

    // 4) 展示结果
    if (!mounted) return;
    if (sources.isEmpty) {
      final replyText = webEnabled
          ? (isZh
              ? '😔 抱歉，联网搜索后未找到 "$query" 的可下载链接。\n\n'
                  '可能原因：\n'
                  '• 搜索引擎未返回有效直链\n'
                  '• 所有候选链接验证失败\n\n'
                  '建议：换一个关键词或直接提供文件 URL。'
              : '😔 Sorry, no downloadable links found for "$query" after web search.\n\n'
                  'Possible reasons:\n'
                  '• Search engine returned no direct links\n'
                  '• All candidates failed verification\n\n'
                  'Tip: try another keyword or provide the file URL directly.')
          : (isZh
              ? '😔 联网搜索已关闭，无法搜索文件下载来源。\n'
                  '请在 设置 → 联网搜索 中打开总开关后重试。'
              : '😔 Web search is off, cannot search file download sources.\n'
                  'Enable the master switch in Settings → Web Search and retry.');
      assistantMsg.content = replyText;
      assistantMsg.showStaleFootnote = true;
      await storage.saveMessage(assistantMsg);
      if (mounted) {
        setState(() {});
        _scrollToBottom();
      }
      _logger.warn('[Chat] No file sources found for "$query"',
          cat: LogCat.download, tag: 'DL');
      return;
    }

    final typeLabel = switch (fileType) {
      'video' => isZh ? '视频' : 'Video',
      'image' => isZh ? '图片' : 'Image',
      'audio' => isZh ? '音频' : 'Audio',
      'document' => isZh ? '文档' : 'Document',
      _ => isZh ? '文件' : 'File',
    };

    final sb = StringBuffer();
    sb.writeln(isZh
        ? '✅ 找到 **${sources.length} 个** $typeLabel 下载来源：'
        : '✅ Found **${sources.length}** $typeLabel source(s):');
    for (int i = 0; i < sources.length; i++) {
      final s = sources[i];
      sb.writeln('${i + 1}. **${s['sourceName']}**  (${s['sourceDomain']})\n'
          '   URL: ${s['downloadUrl']}\n');
    }
    sb.writeln(isZh
        ? '👇 请在下方弹出的面板中选择下载来源。'
        : '👇 Select a source from the panel below.');

    assistantMsg.content = sb.toString();
    assistantMsg.showStaleFootnote = !webEnabled;
    await storage.saveMessage(assistantMsg);
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }

    // 5) 弹出文件来源选择面板
    _showFileSourceSelectorSheet(query, fileType, sources);
  }

  /// 文件来源选择面板
  void _showFileSourceSelectorSheet(
    String query,
    String fileType,
    List<Map<String, String>> sources,
  ) {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final typeLabel = switch (fileType) {
      'video' => isZh ? '视频' : 'Video',
      'image' => isZh ? '图片' : 'Image',
      'audio' => isZh ? '音频' : 'Audio',
      'document' => isZh ? '文档' : 'Document',
      _ => isZh ? '文件' : 'File',
    };

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            final colorScheme = Theme.of(context).colorScheme;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.insert_drive_file,
                            color: colorScheme.onPrimaryContainer),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                isZh
                                    ? '$typeLabel下载：$query'
                                    : '$typeLabel download: $query',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 2),
                            Text(
                                isZh
                                    ? '找到 ${sources.length} 个来源'
                                    : 'Found ${sources.length} source(s)',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      controller: scrollController,
                      itemCount: sources.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final s = sources[index];
                        return _FileSourceCard(
                          source: s,
                          typeLabel: typeLabel,
                          onTap: () {
                            Navigator.pop(context);
                            _downloadFileFromSource(s, typeLabel);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 下载选中的文件源
  Future<void> _downloadFileFromSource(
    Map<String, String> source,
    String typeLabel,
  ) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final dlSvc = context.read<AppDownloadService>();
    final url = source['downloadUrl']!;
    final fileName = source['fileName'];

    // v1.5.0：调用方主动生成 taskId 传入，便于 SnackBar 取消按钮调 cancelDownload
    final taskId = 'manual_${DateTime.now().millisecondsSinceEpoch}';

    // 用 SnackBar 显示进度
    final snackBar = SnackBar(
      content: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
              child:
                  Text(isZh ? '正在下载$typeLabel…' : 'Downloading $typeLabel...')),
        ],
      ),
      duration: const Duration(days: 1),
      action: SnackBarAction(
        label: isZh ? '取消' : 'Cancel',
        onPressed: () => dlSvc.cancelDownload(taskId),
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(snackBar);

    try {
      final result = await dlSvc.downloadFileFromUrl(
        url: url,
        fileName: fileName,
        taskId: taskId,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isZh
                ? '✅ $typeLabel下载完成：${result['fileName']}'
                : '✅ $typeLabel download complete: ${result['fileName']}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isZh ? '❌ 下载失败：$e' : '❌ Download failed: $e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  // ==========================================================================
  // 老流程兜底（仅在 没走 ReAct 时 被 _sendMessage 调用）
  //   流程：LLM judgeDownloadIntentViaLLM → 正则兜底 → 调 _presentDownloadSources
  // v1.6.9 build42：增加「插件启用机制」前置检查 —— 如果用户在插件管理里禁用了下载插件，
  //   不管 ReAct 开不开，下载功能全失效（符合用户预期：禁用就是真的禁用）。
  // ==========================================================================
  Future<bool> _tryHandleDownloadIntent(String text) async {
    // ✅ BUG B5 修复：插件禁用时老流程也失效
    final registry = context.read<PluginRegistry>();
    final downloadPluginId = 'nexus.builtin.download';
    if (!registry.isEnabled(downloadPluginId)) {
      _logger.info(
          '[Chat] Download plugin is disabled, skip _tryHandleDownloadIntent',
          cat: LogCat.download,
          tag: 'DL');
      return false;
    }

    final apiSvc = context.read<ApiService>();
    final apiCfg = _apiConfig;

    String keyword = '';
    List<String> altKeywords = [];
    List<String> officialDomains = [];
    bool handledByLLM = false;
    if (apiCfg != null) {
      final judged = await apiSvc.judgeDownloadIntentViaLLM(
        apiCfg,
        userText: text,
        timeoutSeconds: 12,
      );
      if (judged != null) {
        final isDl = judged['isDownloadIntent'] == true ||
            (judged['confidence'] is num &&
                (judged['confidence'] as num).toDouble() >= 0.75);
        final name = (judged['appNameCanonical'] as String?)?.trim() ?? '';
        final kw = List<String>.from(
            (judged['searchKeywords'] as List?) ?? <String>[]);
        final domains = List<String>.from(
            (judged['officialDomains'] as List?) ?? <String>[]);
        if (isDl && (name.isNotEmpty || kw.isNotEmpty)) {
          handledByLLM = true;
          keyword = name.isNotEmpty ? name : (kw.isNotEmpty ? kw.first : '');
          altKeywords = [
            ...kw.where((k) => k != keyword && k.trim().isNotEmpty).take(3)
          ];
          officialDomains =
              domains.where((d) => d.trim().isNotEmpty).take(2).toList();
          _logger.info(
            '[Chat] Download intent via LLM (fallback): keyword="$keyword", alts=$altKeywords',
            tag: 'DL',
          );
        }
      }
    }
    if (!handledByLLM) {
      final k = AppDownloadService.detectDownloadIntent(text);
      if (k == null) return false;
      keyword = k;
      _logger.info(
          '[Chat] Download intent via regex fallback: keyword=$keyword',
          cat: LogCat.download,
          tag: 'DL');
    }
    if (keyword.trim().isEmpty) return false;

    await _presentDownloadSources(
      userText: text,
      keyword: keyword,
      altKeywords: altKeywords,
      officialDomains: officialDomains,
    );
    return true;
  }

  /// 包装 _tryHandleDownloadIntent：复用已保存/加入 UI 的 userMsg
  /// （供非 ReAct 分支调用，避免 user 消息重复保存）
  Future<bool> _tryHandleDownloadIntentWithExisting(
    ChatMessage userMsg,
    String text,
  ) async {
    // ✅ BUG B5 修复：插件禁用时老流程也失效
    final registry = context.read<PluginRegistry>();
    final downloadPluginId = 'nexus.builtin.download';
    if (!registry.isEnabled(downloadPluginId)) {
      _logger.info(
          '[Chat] Download plugin is disabled, skip _tryHandleDownloadIntentWithExisting',
          cat: LogCat.download,
          tag: 'DL');
      return false;
    }

    // 内部逻辑复用：先 LLM 判别 / 正则判别，得到 (keyword, alts, domains)
    final apiSvc = context.read<ApiService>();
    final apiCfg = _apiConfig;

    String keyword = '';
    List<String> altKeywords = [];
    List<String> officialDomains = [];
    bool hit = false;
    if (apiCfg != null) {
      final judged = await apiSvc.judgeDownloadIntentViaLLM(
        apiCfg,
        userText: text,
        timeoutSeconds: 12,
      );
      if (judged != null) {
        final isDl = judged['isDownloadIntent'] == true ||
            (judged['confidence'] is num &&
                (judged['confidence'] as num).toDouble() >= 0.75);
        final name = (judged['appNameCanonical'] as String?)?.trim() ?? '';
        final kw = List<String>.from(
            (judged['searchKeywords'] as List?) ?? <String>[]);
        final domains = List<String>.from(
            (judged['officialDomains'] as List?) ?? <String>[]);
        if (isDl && (name.isNotEmpty || kw.isNotEmpty)) {
          hit = true;
          keyword = name.isNotEmpty ? name : (kw.isNotEmpty ? kw.first : '');
          altKeywords = [
            ...kw.where((k) => k != keyword && k.trim().isNotEmpty).take(3)
          ];
          officialDomains =
              domains.where((d) => d.trim().isNotEmpty).take(2).toList();
        }
      }
    }
    if (!hit) {
      final k = AppDownloadService.detectDownloadIntent(text);
      if (k == null) return false;
      keyword = k;
    }
    if (keyword.trim().isEmpty) return false;

    _logger.info(
        '[Chat] Download intent via fallback-with-existing: keyword=$keyword',
        cat: LogCat.download,
        tag: 'DL');

    // 把 UI 里之前的 userMsg 拿掉，避免 presentDownloadSources 又创建一个（实际用 existingUserMsg 参数传入即可）
    await _presentDownloadSources(
      userText: text,
      keyword: keyword,
      altKeywords: altKeywords,
      officialDomains: officialDomains,
      existingUserMsg: userMsg,
    );
    return true;
  }

  // ==========================================================================
  // build 11：ReAct 自主思考 + 搜索循环（Chatbox 风格）
  // v1.3.3 build 13 重构：
  //   - 支持自动档（reactAutoMode=true → effort=high，循环上限可调到 100）
  //   - 支持思考期间用户中途插话（pendingFollowupMessages 队列）
  //   - 支持 AI 反向提问 <ask_user>（暂停循环弹对话框，用户回复后注入 working）
  //   - 支持下载 platform 字段（android/pc）
  //   - 支持 20 秒确认机制（_reactLoopStopRequested 用户终止）
  // 步骤：
  //   1. 为 LLM 加上「用 <thinking>/<search query=""/>/<answer>/<download>/<ask_user> 协议」的临时 system 消息
  //   2. 循环 N 轮：调用 API completeChat → 解析 → 处理
  //      - <thinking> → 追加进 assistantMsg.reasoningSteps
  //      - <search query="..." /> → 执行搜索 → 拼 toolresult 回复
  //      - <ask_user>问题||选项1||选项2</ask_user> → 暂停循环弹对话框，用户回复注入 working
  //      - <answer> → 拿到最终回答，渲染进气泡 content，结束循环
  //      - <download intent="true" platform="android|pc" ... /> → 触发下载流程
  //   3. 每轮 LLM 返回后先 drain pendingFollowupMessages（用户中途插话）到 workingMessages
  // ==========================================================================
  Future<void> _runReActLoop(
    ChatMessage userMsg,
    ApiService apiSvc,
    StorageService storage,
  ) async {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final isAuto = _webSearchCfg.reactAutoMode;
    final maxRounds = _webSearchCfg.effectiveMaxRounds;
    final effort = ApiService.reasoningEffortForConfig(_webSearchCfg);

    // v1.7.9 (M7 修复)：循环内多轮 await 之后不能再 context.read（页面退出后
    // 会抛 "deactivated widget's ancestor" 崩溃）—— 方法入口一次性缓存服务引用
    final dlSvc = context.read<AppDownloadService>();

    // v1.6.9：PluginRegistry 决定哪些插件能 dispatch，哪些插件的协议能进 prompt。
    //   - 禁用的插件 → registry.dispatch 跳过（不触发功能）
    //   - 禁用的插件 → promptProtocol 也不拼给 AI（AI 根本看不到协议，自然不会输出对应标签）
    final registry = context.read<PluginRegistry>();
    final enabledPlugins = registry.plugins
        .where((p) => registry.isEnabled(p.metadata.id))
        .toList(growable: false);
    final hasDownloadPlugin =
        enabledPlugins.any((p) => p.triggerType == 'download');

    _logger.info(
      '[ReAct] Entering loop, STREAMING mode, auto=$isAuto, maxRounds=$maxRounds, effort=$effort, enabledPlugins=${enabledPlugins.map((p) => p.triggerType).join(',')}',
      cat: LogCat.react,
      tag: 'ReAct',
    );

    // v1.6.9：按用户要求"分成两半"——启动的插件拼 promptProtocol（启动版），
    // 禁用的插件完全不拼（不启动版）。市场安装的新插件 register 时顺序在 system 之后，自然追加。
    final reactProtocolPrompt =
        buildReactSystemPromptFromPlugins(enabledPlugins);
    // 构造一个"临时 system 消息"：给 AI 注入 ReAct 协议（不落库，只在本循环内存中用）
    final reactSystemMsg = ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.system,
      content: reactProtocolPrompt,
    );

    // 用于发给 API 的消息列表（系统 prompt + 历史 + user + 每轮 toolresult）
    // 注意：assistant 的 <thinking>/<search> 直接当 assistant 消息发回去（原始完整文本）
    final workingMessages = <ChatMessage>[];
    for (final m in _limitedContext(_messages).where(
        (m) => m.role != MessageRole.assistant || m.content.isNotEmpty)) {
      workingMessages.add(m);
    }

    // v1.4.2：自动压缩 —— 基于 token 估算触发（比消息数量更合理）
    // 阈值：当 workingMessages 估算 token > 4000 时触发压缩
    // 保留最近 6 条消息 + 一条 AI 生成的结构化摘要
    if (widget.conversation.autoCompress) {
      final estimatedTokens = ApiService.estimateTokens(workingMessages);
      const tokenThreshold = 4000;
      if (estimatedTokens > tokenThreshold && workingMessages.length > 8) {
        const keepRecent = 6;
        final oldPart = workingMessages
            .sublist(0, workingMessages.length - keepRecent)
            .toList();
        final recentPart = workingMessages
            .sublist(workingMessages.length - keepRecent)
            .toList();
        try {
          final apiSvcForSum = context.read<ApiService>();
          final summary = await _summarizeMessages(apiSvcForSum, oldPart);
          if (summary.isNotEmpty) {
            workingMessages
              ..clear()
              ..add(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content:
                    '【上下文压缩摘要 · ${oldPart.length} 条 · ~${estimatedTokens} tokens】\n$summary',
              ))
              ..addAll(recentPart);
            _logger.info(
                '[Chat] Auto-compressed: ${oldPart.length} msgs / ~${estimatedTokens} tokens → 1 summary',
                tag: 'Chat');
          }
        } catch (e) {
          _logger.warn('[Chat] Auto-compress failed, keep original context: $e',
              tag: 'Chat');
        }
      }
    }

    workingMessages.add(userMsg);

    // UI：先加 userMsg + assistant 占位（带"思考中…"初始 thinking step）
    final assistantMsg = ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.assistant,
      content: '',
      showStaleFootnote: false, // ReAct 主动搜索过的话不给过时脚注
      injectedWebSearchCount: 0,
    )..addReasoning(ReasoningStep(
        'thinking',
        isAuto
            ? (isZh
                ? '正在思考是否需要联网搜索…（自动档：AI 自决轮次，上限 $maxRounds 轮）'
                : 'Thinking whether to search the web... (Auto: AI decides, up to $maxRounds rounds)')
            : (isZh
                ? '正在思考是否需要联网搜索…'
                : 'Thinking whether to search the web...')));

    // 重置终止标志
    _reactLoopStopRequested = false;

    if (mounted) {
      setState(() {
        if (!_messages.contains(userMsg)) _messages.add(userMsg);
        _messages.add(assistantMsg);
        _isStreaming = true;
      });
      _scrollToBottom();
    }

    // ===== v1.4.5：ReAct 循环实时写入 DB（防崩溃丢失）—— 预插入 + 重置节流 =====
    _lastAssistantDbSaveMs = 0;
    _lastAssistantDbSaveLen = 0;
    await storage.saveMessage(assistantMsg);

    // v1.3.4：20 秒确认改成"向 AI 自检"——不弹窗，而是注入系统自检消息
    // AI 下一轮看到消息后输出 <self_check continue="true|false" reason="..."/>
    // continue=false → 终止循环；continue=true → 继续
    Timer? checkTimer;
    if (_enable20sCheck) {
      checkTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (!mounted || !_isStreaming) return;
        _injectSelfCheck(workingMessages, assistantMsg);
      });
    }

    final apiCfg = _apiConfig!;
    bool answered = false;
    var mcpCalls = 0;
    const maxMcpCallsPerMessage = 8;

    try {
      for (int round = 0; round < maxRounds + 1; round++) {
        // 用户在 20 秒确认弹窗里点了"终止" → 立即跳出循环
        if (_reactLoopStopRequested) break;

        // ===== 每轮开始前先 drain 用户中途插话队列 =====
        if (_pendingFollowupMessages.isNotEmpty) {
          final pending = List<String>.from(_pendingFollowupMessages);
          _pendingFollowupMessages.clear();
          if (mounted) setState(() {}); // 更新 pendingFollowupCount 显示
          for (final text in pending) {
            workingMessages.add(ChatMessage.create(
              conversationId: widget.conversation.id,
              role: MessageRole.user,
              content: '(用户中途补充)：$text',
            ));
            assistantMsg.appendLastThinking(isZh
                ? '\n📩 用户中途补充了一条消息：「$text」，已加入思考上下文。\n'
                : '\n📩 User added a message mid-thinking: "$text", injected into context.\n');
          }
          if (mounted) setState(() {});
        }

        // 发给 API：原始 system prompt + ReAct 协议 system + working messages
        final reqList = <ChatMessage>[];
        if (apiCfg.systemPrompt.isNotEmpty) {
          reqList.add(ChatMessage.create(
            conversationId: widget.conversation.id,
            role: MessageRole.system,
            content: apiCfg.systemPrompt,
          ));
        }
        reqList.add(reactSystemMsg);
        reqList.addAll(workingMessages);

        // ---- 调 LLM（v1.5.5：流式化，实时显示思考过程）----
        final thinkingProgressMsg = isZh
            ? (isAuto
                ? '🧠 思考中…（轮次 ${round + 1}/${maxRounds + 1}，自动档 $effort）'
                : '🧠 思考中…（轮次 ${round + 1}/${maxRounds + 1}，程度 $effort）')
            : (isAuto
                ? '🧠 Thinking... (round ${round + 1}/${maxRounds + 1}, auto $effort)'
                : '🧠 Thinking... (round ${round + 1}/${maxRounds + 1}, effort $effort)');
        _logger.info(
            '[ReAct] Round ${round + 1} start, effort=$effort, auto=$isAuto',
            cat: LogCat.react,
            tag: 'ReAct');
        assistantMsg.appendLastThinking('\n$thinkingProgressMsg\n');
        if (mounted) setState(() {});

        // v1.5.5：用 streamChat 替代 completeChat，流式收集 rawResp 的同时实时显示思考内容
        final rawBuf = StringBuffer();
        await for (final chunk in apiSvc.streamChat(
          config: _conversationApiConfig,
          messages: reqList,
          reasoningEffort: effort,
          yieldReasoning: true,
        )) {
          if (_reactLoopStopRequested) break;
          rawBuf.write(chunk);
          // 实时显示：去掉 ReAct 协议标签，只把纯文本追加到 thinking step
          final display = _stripReActTagsForStream(chunk);
          if (display.isNotEmpty) {
            assistantMsg.appendLastThinking(display);
            if (mounted) setState(() {});
          }
        }
        final rawResp = rawBuf.toString();

        _logger.verbose(
            '[ReAct] Round ${round + 1} raw response (${rawResp.length} chars): ${rawResp.substring(0, rawResp.length > 500 ? 500 : rawResp.length)}${rawResp.length > 500 ? '...' : ''}',
            cat: LogCat.react,
            tag: 'ReAct');

        // 用户在 LLM 调用期间点了"终止" → 不解析了直接跳出
        if (_reactLoopStopRequested) break;

        // ---- v1.6.9：解析 LLM 输出，再用 PluginRegistry.dispatch 分发插件执行 ----
        //   这里做的事情：
        //     1) _parseReActOutput 依然按顺序识别 <thinking>/<search>/<answer> 等片段
        //     2) 对每个片段构造 PluginContext（承载 workingMessages/UI/SnackBar/保存 assistant 等回调）
        //     3) 交给 registry.dispatch(type, attrs) → 一行分发，不再 if/else 317 行
        final parsed = _parseReActOutput(rawResp);
        int totalSearchHitsSnapshot = 0;
        for (final p in parsed) {
          final type = p['type']!;
          if (type == 'mcp_call') {
            if (mcpCalls >= maxMcpCallsPerMessage) {
              _logger.warn('[ReAct] MCP call limit reached for message',
                  cat: LogCat.react, tag: 'ReAct');
              _reactLoopStopRequested = true;
              break;
            }
            mcpCalls++;
          }
          if (type == 'thinking') {
            // v1.5.5 流式模式：流式过程中已实时追加，解析时跳过避免重复
            continue;
          }
          // 构造 PluginContext：作为「插件调用的 UI/服务 隔离层」，
          // 统一管理 setState / mounted / SnackBar / workingMessages append / answer finalize 等行为。
          final pc = PluginContext(
            workingMessages: workingMessages,
            assistantMsg: assistantMsg,
            webSearchCfg: _webSearchCfg,
            conversationApiConfig: _conversationApiConfig,
            userMsg: userMsg,
            rawResp: rawResp,
            storage: storage,
            // WebSearchService 是静态类，没有 instance，所以 webSearch 参数留空
            // SearchPlugin 会直接用静态方法 WebSearchService.searchGeneral(...)
            // v1.7.9 (M7)：用入口缓存的 dlSvc，不再 context.read（跨 async 崩溃）
            appDownload: dlSvc,
            logger: _logger,
            answerBuffer: StringBuffer(),
            answered: answered,
            mounted: mounted,
            rootContext: mounted ? context : null,
            onRequestStop: () {
              _reactLoopStopRequested = true;
            },
            onAppendReasoning: (text) {
              if (mounted) setState(() {});
            },
            onAppendUserMessage: (text) {
              if (mounted) setState(() {});
            },
            onFinalizeAnswer: (text,
                {injectedWebSearchCount = 0, forceSave = true}) async {
              assistantMsg.content = text;
              assistantMsg.injectedWebSearchCount = injectedWebSearchCount;
              if (forceSave) {
                await _throttledSaveAssistantContent(
                    storage, assistantMsg, text,
                    force: true);
              }
              answered = true;
            },
            onSetState: (fn) {
              if (mounted) {
                fn();
                setState(() {});
              }
            },
            onSaveAssistantContent: (count) async {
              totalSearchHitsSnapshot = count;
              await _throttledSaveAssistantContent(
                  storage, assistantMsg, assistantMsg.content);
            },
            onShowAskUser: (question, options) async {
              return mounted
                  ? await _showAskUserDialog(question, options)
                  : null;
            },
            onPresentAppDownloadSources: hasDownloadPlugin
                ? ({
                    required userText,
                    required keyword,
                    required altKeywords,
                    required officialDomains,
                    existingUserMsg,
                    existingPlaceholder,
                    platform = 'android',
                  }) async {
                    answered = true;
                    await _presentDownloadSources(
                      userText: userText,
                      keyword: keyword,
                      altKeywords: altKeywords,
                      officialDomains: officialDomains,
                      existingUserMsg: existingUserMsg,
                      existingPlaceholder: existingPlaceholder,
                      platform: platform,
                    );
                  }
                : null,
            onAnsweredChanged: (value) {
              answered = value;
            },
            onPresentFileSources: hasDownloadPlugin
                ? ({
                    required userText,
                    required query,
                    fileType,
                    existingUserMsg,
                    existingPlaceholder,
                  }) async {
                    answered = true;
                    await _presentFileDownloadSources(
                      userText: userText,
                      query: query,
                      fileType: fileType ?? 'file',
                      existingUserMsg: existingUserMsg,
                      existingPlaceholder: existingPlaceholder,
                    );
                  }
                : null,
            onGenericDownload: hasDownloadPlugin
                ? (url, amsg) async {
                    answered = true;
                    await _reactGenericDownload(url, amsg);
                  }
                : null,
          );
          // ---- 核心：一行 dispatch，替换 317 行 if/else ----
          final attrs = Map<String, dynamic>.from(p);
          attrs['raw'] = rawResp;
          await registry.dispatch(context, pc, type, attrs);
          // 插件通过 setAnswered / finalizeAnswer 标志是否本轮结束
          if (pc.answered) {
            answered = true;
          }
          if (totalSearchHitsSnapshot > 0) {
            assistantMsg.injectedWebSearchCount = totalSearchHitsSnapshot;
          }
          // 同步 pc 内维护的 mounted 回外层（防 mounted 不一致）
          if (pc.totalSearchHits > 0) {
            assistantMsg.injectedWebSearchCount = pc.totalSearchHits;
          }
          if (answered || _reactLoopStopRequested) break;
        } // end for parsed
        // ===== v1.4.5：ReAct 每轮解析完毕 → 节流保存（防崩溃丢思考步骤 + 已生成 answer） =====
        unawaited(_throttledSaveAssistantContent(
            storage, assistantMsg, assistantMsg.content));
        if (answered || _reactLoopStopRequested) break;
      } // end for rounds

      // ---- 兜底：到最后一轮还是没 <answer> → 强制取最后一个 assistant 消息的答案
      if (!answered) {
        if (_reactLoopStopRequested) {
          // 用户主动终止 → 取最近一条 assistant 内容
          ChatMessage? lastWorking;
          for (int i = workingMessages.length - 1; i >= 0; i--) {
            final m = workingMessages[i];
            if (m.role == MessageRole.assistant && m.content.isNotEmpty) {
              lastWorking = m;
              break;
            }
          }
          final fallback = lastWorking?.content ?? '';
          final lastAnswer = _extractFirstAnswer(fallback);
          assistantMsg.content = lastAnswer.isNotEmpty
              ? '$lastAnswer\n\n${isZh ? '_(用户已终止思考，输出当前进度)_' : '_(User stopped thinking, showing current progress)_'}'
              : (isZh
                  ? '_(用户已终止思考，未生成有效回答)_'
                  : '_(User stopped thinking, no valid answer generated)_');
          // ===== v1.4.5：ReAct 用户终止兜底 answer → 强制保存 =====
          unawaited(_throttledSaveAssistantContent(
              storage, assistantMsg, assistantMsg.content,
              force: true));
          _logger.info('[ReAct] User stopped the loop at round end',
              cat: LogCat.react, tag: 'ReAct');
        } else {
          ChatMessage? lastWorking;
          for (int i = workingMessages.length - 1; i >= 0; i--) {
            final m = workingMessages[i];
            if (m.role == MessageRole.assistant && m.content.isNotEmpty) {
              lastWorking = m;
              break;
            }
          }
          final fallback = lastWorking?.content ?? '';
          final lastAnswer = _extractFirstAnswer(fallback);
          assistantMsg.content = lastAnswer.isNotEmpty
              ? lastAnswer
              : (isZh
                  ? '（抱歉，达到最大思考轮次（$maxRounds 轮）仍未得出最终回答。${isAuto ? "可在 20 秒确认弹窗里手动终止，或" : ""}在设置中把思考程度调高后重试。）'
                  : '(Sorry, reached the max thinking rounds ($maxRounds) without a final answer. ${isAuto ? "You can stop manually in the 20s confirm dialog, or " : ""}raise the thinking level in Settings and retry.)');
          _logger.warn(
              '[ReAct] Reached max rounds without <answer> tag, used fallback',
              cat: LogCat.react,
              tag: 'ReAct');
        }
        assistantMsg.injectedWebSearchCount =
            assistantMsg.injectedWebSearchCount > 0
                ? assistantMsg.injectedWebSearchCount
                : 0;
        assistantMsg.showStaleFootnote =
            assistantMsg.injectedWebSearchCount == 0;
      }
    } catch (e, st) {
      _logger.error('[ReAct] loop crashed',
          error: e, stack: st, cat: LogCat.react, tag: 'ReAct');
      assistantMsg.content = isZh
          ? '❌ 思考过程出错：${e.toString()}\n\n你可以：\n1. 降低思考程度再试；\n2. 临时关闭「自主思考搜索循环」，退回普通联网搜索模式。'
          : '❌ Thinking loop error: ${e.toString()}\n\nTry:\n1. Lower the thinking level;\n2. Temporarily disable the autonomous thinking loop and fall back to normal web search mode.';
      assistantMsg.showStaleFootnote = true;
      // ===== v1.4.5：ReAct 崩溃 catch 里写的错误提示 → 强制保存 =====
      unawaited(_throttledSaveAssistantContent(
          storage, assistantMsg, assistantMsg.content,
          force: true));
    } finally {
      checkTimer?.cancel();
      _reactLoopStopRequested = false;
      // v1.3.6：保存 token 用量
      // v1.7.9 (M7)：finally 位于多轮 await 之后，用方法参数 apiSvc
      // （之前 context.read 在页面退出后抛 deactivated widget 崩溃）
      assistantMsg.promptTokens =
          apiSvc.totalPromptTokens > 0 ? apiSvc.totalPromptTokens : null;
      assistantMsg.completionTokens = apiSvc.totalCompletionTokens > 0
          ? apiSvc.totalCompletionTokens
          : null;
      assistantMsg.totalTokens =
          apiSvc.totalAllTokens > 0 ? apiSvc.totalAllTokens : null;
      await storage.saveMessage(assistantMsg);
      final finalSearchCount = assistantMsg.injectedWebSearchCount > 0
          ? assistantMsg.injectedWebSearchCount
          : 0;
      if (mounted) {
        setState(() {
          _isStreaming = false;
        });
        _scrollToBottom();
        if (finalSearchCount > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.tr('searchResultCount',
                  args: {'count': '$finalSearchCount'})),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  // ==========================================================================
  // v1.3.3 build 13 新增：AI 反向提问对话框
  // 解析到 <ask_user> 标签时调用，返回用户回复（选项按钮点选或自由输入）
  // options 为空时只显示自由输入框；非空时显示选项按钮 + "其他"输入框
  // ==========================================================================
  Future<String?> _showAskUserDialog(
      String question, List<String> options) async {
    if (!mounted) return null;
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final textCtrl = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.help_outline, color: cs.primary, size: 22),
            const SizedBox(width: 8),
            Text(isZh ? 'AI 想问你' : 'AI wants to ask you'),
          ],
        ),
        // v1.6.3：content 加滚动 + 高度限制，选项过多时不再把底部按钮/输入框顶出屏幕
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.5,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    question,
                    style: TextStyle(
                      fontSize: 15,
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (options.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: options.map((opt) {
                      return ActionChip(
                        label: Text(opt),
                        onPressed: () => Navigator.pop(ctx, opt),
                      );
                    }).toList(),
                  ),
                if (options.isNotEmpty) const SizedBox(height: 8),
                Text(isZh ? '或自己输入：' : 'Or type your own:',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                TextField(
                  controller: textCtrl,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    isDense: true,
                    hintText: isZh ? '（可留空跳过）' : '(leave blank to skip)',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text(isZh ? '跳过' : 'Skip'),
          ),
          FilledButton(
            onPressed: () {
              final t = textCtrl.text.trim();
              Navigator.pop(ctx, t.isNotEmpty ? t : null);
            },
            child: Text(isZh ? '提交' : 'Submit'),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // v1.3.3 build 13 新增：20 秒确认对话框（防卡壳）
  // 用户可选"继续思考"或"终止并输出当前结果"
  // ==========================================================================
  /// v1.3.4：向 workingMessages 注入"系统自检"消息（替代之前的弹窗方案）
  /// AI 下一轮看到这条消息后会输出 <self_check continue="true|false" reason="..."/>
  /// 不弹窗、不打断用户，纯 AI 自检。continue=false 时主循环终止。
  void _injectSelfCheck(
      List<ChatMessage> workingMessages, ChatMessage assistantMsg) {
    // v1.7.4 fix: 从 assistantMsg.content 解析真实的 ReAct 标签内容，而非 reasoningSteps 中的 UI 进度文字
    final rawContent = assistantMsg.content;
    final parsed = _parseReActOutput(rawContent);
    final recentSteps = parsed
        .where((p) => p['type'] == 'thinking' || p['type'] == 'search')
        .toList()
        .reversed
        .take(3)
        .map((p) {
          final type = p['type']!;
          final content = p['content'] ?? '';
          final display = content.length > 80 ? content.substring(0, 80) : content;
          return '• [$type] $display';
        })
        .join('\n');
    workingMessages.add(ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: '[系统自检] 你已思考一段时间。最近步骤：\n$recentSteps\n\n'
          '请判断：\n'
          '1) 你是否在重复同样的搜索/思考动作？\n'
          '2) 是否已经接近答案，需要继续？\n'
          '3) 是否该终止并基于已有信息给出回答？\n\n'
          '请输出 <self_check continue="true|false" reason="简短理由" />',
    ));
    _logger.info('[Chat] Self-check injected (20s timer)',
        cat: LogCat.chat, tag: 'Chat');
  }

  // 解析 <thinking>/<search query="..."/>/<answer>/<download />/<ask_user>...</ask_user> 混合输出，按出现顺序返回 list
  // piece: {'type': 'thinking' | 'search' | 'answer' | 'download' | 'ask_user', 'content': String, +attributes...}
  // v1.3.3: <ask_user> 的 content 可能含 "问题||选项1||选项2" 格式（用 || 分隔预设选项）
  List<Map<String, String>> _parseReActOutput(String s) => parseReActOutput(s);

  /// v1.5.5：流式显示时去掉 ReAct 协议标签，只保留纯文本（避免用户看到 <search>/<thinking> 等）
  String _stripReActTagsForStream(String s) {
    return s
        .replaceAll(
          RegExp(r'<mcp_call\b[^>]*>[\s\S]*?</mcp_call\s*>',
              caseSensitive: false),
          '',
        )
        .replaceAll(
            RegExp(r'<[^>]+/>'), '') // 自闭合 <search .../> / <download .../>
        .replaceAll(
            RegExp(r'</?[^>]+>'), '') // 配对 <thinking> </thinking> / <answer> 等
        .trim();
  }

  // v1.3.7 Bug #7：方法名从 _extractLastAnswer 改为 _extractFirstAnswer
  // 因为实现用 firstMatch（取第一个）。AI 协议规定只输出一次 <answer>，
  // firstMatch 与 lastMatch 行为等价，方法名与实现保持一致即可。
  String _extractFirstAnswer(String s) {
    final m = RegExp(r'<answer>([\s\S]*?)</answer>').firstMatch(s);
    if (m != null) return m.group(1)!.trim();
    // 没 <answer>：如果存在 <thinking> 就取它之外的部分；否则全返回
    final t = s.replaceAll(RegExp(r'<thinking>[\s\S]*?</thinking>'), '').trim();
    if (t.isNotEmpty) return t;
    return s;
  }

  // ===== v1.3.6：📎 附件选择 / 删除 =====
  /// 点 📎 按钮：弹出底部选择条（相册 / 拍照 / 文档）
  Future<void> _pickAttachment() async {
    if (_isStreaming) return;
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_outlined, color: cs.primary),
              title: Text(isZh ? '相册选照片' : 'Choose from gallery'),
              onTap: () async {
                Navigator.pop(ctx);
                final att = await _attachmentService.pickImageFromGallery();
                if (att != null && mounted) {
                  setState(() => _pendingAttachments.add(att));
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.camera_alt_outlined, color: cs.primary),
              title: Text(isZh ? '拍照' : 'Take photo'),
              onTap: () async {
                Navigator.pop(ctx);
                final att = await _attachmentService.pickImageFromCamera();
                if (att != null && mounted) {
                  setState(() => _pendingAttachments.add(att));
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.description_outlined, color: cs.primary),
              title: Text(isZh
                  ? '选文档（txt/md/pdf/docx）'
                  : 'Pick document (txt/md/pdf/docx)'),
              onTap: () async {
                Navigator.pop(ctx);
                final att = await _attachmentService.pickDocument();
                if (att != null && mounted) {
                  setState(() => _pendingAttachments.add(att));
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.close, color: cs.onSurfaceVariant),
              title: Text(l.tr('cancel')),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  void _removeAttachment(MessageAttachment att) {
    setState(() => _pendingAttachments.remove(att));
  }

  // ==========================================================================
  // 发送消息（AI 对话 + 可选联网搜索上下文注入）
  // v1.3.2 顺序：
  //   ① 判定是否走 ReAct（AI API 配置 + 联网总开关 + 🌐按钮 + ReAct 开关）
  //   ② YES → 进 _runReActLoop，思考→搜索→搜索→最后出 <answer> 或 <download>
  //     · 如果 AI 判定为下载请求，会输出 <download> 标签，
  //       内部再调 _presentDownloadSources（真正的 AI+联网 下载流程）
  //   ③ NO  → 先调用老捷径 _tryHandleDownloadIntent（LLM/正则兜底判断下载）
  //     · 命中 → 直接出来源面板
  //     · 没命中 → 按"一次性前置搜索 + 流式回复"或"纯AI回复"走
  // ==========================================================================
  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    // v1.3.6：允许只发附件不写文字（图片提问等场景）
    if (text.isEmpty && _pendingAttachments.isEmpty) return;

    // v1.3.3 build 13：思考循环进行中 → 用户中途插话入队，不打断
    if (_isStreaming) {
      _inputController.clear();
      _pendingFollowupMessages.add(text);
      _logger.info(
          '[Chat] Followup queued during streaming: len=${text.length}, queueSize=${_pendingFollowupMessages.length}',
          cat: LogCat.chat,
          tag: 'Chat');
      final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
      if (mounted) {
        setState(() {}); // 更新 ChatInput 的 pendingFollowupCount 显示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isZh
                ? '📩 已加入思考队列（第 ${_pendingFollowupMessages.length} 条）。AI 下一轮会处理。'
                : '📩 Queued (#${_pendingFollowupMessages.length}). AI will process it next round.'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            width: 300,
          ),
        );
      }
      return;
    }

    _inputController.clear();
    // v1.3.6：快照待发送附件并清空输入栏的 chip 预览
    final pendingAtts = List<MessageAttachment>.from(_pendingAttachments);
    if (mounted) setState(() => _pendingAttachments.clear());
    // 🌐 开关：常驻（不再每次发送后 reset 为 false）
    final bool wasSearchMode = _searchMode;

    if (_apiConfig == null) {
      // 没 AI API Key：只能走"纯下载捷径（正则+内置目录+联网）"兜底，因为无法调 AI
      final handled = await _tryHandleDownloadIntent(text);
      if (handled) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(AppLocalizations.of(context).tr('apiConfigNotFound'))),
        );
      }
      return;
    }

    final l = AppLocalizations.of(context);
    final storage = context.read<StorageService>();
    final apiSvc = context.read<ApiService>();

    // v1.3.6：重置 token 计数器
    apiSvc.resetTokenCounters();

    final userMsg = ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: text,
    );
    // v1.3.6：把待发送附件挂到 userMsg（API 调用时由 _buildMessagesPayload 处理多模态）
    if (pendingAtts.isNotEmpty) {
      userMsg.attachments.addAll(pendingAtts);
    }
    await storage.saveMessage(userMsg);

    // ===== v1.3.2：ReAct 自主思考 + 搜索循环（Chatbox 风格）=====
    // v1.6.9 build42 修复问题4：思考循环与联网搜索解耦——
    //   - 不再依赖 wasSearchMode / webSearchEnabled（关搜索也能思考，只思考不搜索）
    //   - 依赖 self_check 插件启用（失去自检终止保护则 🧠 整体禁用）
    final registry = context.read<PluginRegistry>();
    final shouldUseReAct = _webSearchCfg.reactEnabled &&
        _webSearchCfg.reactMaxRounds > 0 &&
        registry.isEnabled(PluginRegistry.kSelfCheckPluginId) &&
        _apiConfig != null; // 无 AI 配置时不跑自主思考

    if (shouldUseReAct) {
      await _runReActLoop(userMsg, apiSvc, storage);
      return;
    }

    // ===== 未触发 ReAct 时：下载意图先判（不会被先拦截了）=====
    // 先手动把 userMsg 加到 UI 上，因为 _tryHandleDownloadIntent 如果命中也会优先加 existingUserMsg
    if (mounted) {
      setState(() {
        if (!_messages.contains(userMsg)) _messages.add(userMsg);
      });
      _scrollToBottom();
    }
    final handled = await _tryHandleDownloadIntentWithExisting(userMsg, text);
    if (handled) return;

    // ===== 之前的"一次性前置搜索 + 流式回复"流程 =====
    String searchContextBlock = '';
    bool willWarnStaleKnowledge = true;
    int searchHitCount = 0;
    if (wasSearchMode && _webSearchCfg.webSearchEnabled) {
      _logger.info(
        '[Chat] Web search before send: query length=${text.length}',
        tag: 'Chat',
      );
      final placeholder = ChatMessage.create(
        conversationId: widget.conversation.id,
        role: MessageRole.assistant,
        content: '🌐 ${l.tr('searchingNow')}',
      );
      if (mounted) {
        setState(() {
          // v1.7.9 (M6 修复)：userMsg 在 L1824 已加入，这里只补 placeholder
          // （之前无条件重复 add → 消息气泡重复显示 + API payload 把重复 user 消息发给 LLM）
          if (!_messages.contains(userMsg)) _messages.add(userMsg);
          _messages.add(placeholder);
        });
        _scrollToBottom();
      }

      final results = await WebSearchService.searchGeneral(text, _webSearchCfg);
      searchHitCount = results.length;
      _logger.verbose(
          '[Chat] Pre-send search results ($searchHitCount items):\n${results.take(5).map((r) => '  - ${r.title}\n    ${r.url}\n    ${r.snippet.substring(0, r.snippet.length > 100 ? 100 : r.snippet.length)}').join('\n')}',
          cat: LogCat.chat,
          tag: 'Chat');
      if (results.isNotEmpty) {
        searchContextBlock = WebSearchService.formatAsSearchContext(
          results,
          _webSearchCfg,
          query: text,
        );
        willWarnStaleKnowledge = false;
      }
      // remove placeholder before assistant streaming starts
      if (mounted) setState(() => _messages.remove(placeholder));
    }

    // 3) 若没搜索（或搜索无结果）+ 总开关关了 → 也要过时警告（脚注）
    if (!_webSearchCfg.webSearchEnabled) {
      willWarnStaleKnowledge = true;
    }

    // UI：加用户消息 + 空 assistant 占位
    final assistantMsg = ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.assistant,
      content: '',
      // v1.3.1 把"是否加警告脚注 / 注入数"直接绑在消息上，渲染时走淡色 footnote，不再把警告文字塞进正文开头
      showStaleFootnote: willWarnStaleKnowledge,
      injectedWebSearchCount: searchHitCount,
    );

    // v1.6.8 修复 Bug#5：上面有多个 await（_tryHandleDownloadIntent / searchGeneral），
    // 用户可能已退出页面，setState 必须检查 mounted
    if (!mounted) return;
    setState(() {
      if (!_messages.contains(userMsg)) _messages.add(userMsg);
      _messages.add(assistantMsg);
      _isStreaming = true;
    });
    _scrollToBottom();

    final allMessages = _limitedContext(_messages
        .where((m) => m.role != MessageRole.assistant || m.content.isNotEmpty)
        .where((m) => m.id != assistantMsg.id)
        .toList());

    // 如果有搜索上下文块 → 把"用户原始消息 + 上下文块"拼成一条新消息发给 API
    // （不存回数据库，存回数据库的仍保留用户原文，避免污染历史）
    List<ChatMessage> outgoing;
    if (searchContextBlock.isNotEmpty) {
      outgoing = List<ChatMessage>.from(allMessages);
      // 找到最后一条用户消息，替换为 "上下文块 + 原始问题"
      for (int i = outgoing.length - 1; i >= 0; i--) {
        if (outgoing[i].role == MessageRole.user &&
            outgoing[i].id == userMsg.id) {
          outgoing[i] = ChatMessage.create(
            conversationId: userMsg.conversationId,
            role: MessageRole.user,
            content: '$searchContextBlock\n\n用户问题：${userMsg.content}',
          );
          break;
        }
      }
    } else {
      outgoing = allMessages;
    }

    String fullResponse = '';
    try {
      _logger.info(
          '[Chat] Send message: length=${text.length}, searchMode=$wasSearchMode, hits=$searchHitCount',
          cat: LogCat.chat,
          tag: 'Chat');
      _logger.verbose('[Chat] User message: $text',
          cat: LogCat.chat, tag: 'Chat');
      await for (final chunk in apiSvc.streamChat(
        config: _conversationApiConfig,
        messages: outgoing,
      )) {
        fullResponse += chunk;
        // v1.6.8 修复 Bug#4：流式 chunk 循环内 setState 必须检查 mounted，
        // 用户在流式期间按返回键退出页面，未检查会导致 setState after dispose 崩溃
        if (mounted) {
          setState(() {
            _messages.last.content = fullResponse;
          });
        }
        _scrollToBottom();
        // ===== v1.4.5：AI 回复实时写入 DB（防崩溃丢失）—— 流式过程节流保存 =====
        // 注意：不 await，流式优先保证 UI 流畅；IO 本身已串行（SQLite 单线程）
        unawaited(_throttledSaveAssistantContent(
            storage, assistantMsg, fullResponse));
      }

      // v1.3.1：不再在回复最前面塞一大段"⚠️ 可能已过时"，改为气泡底部 footnote（小字体 + 淡色）
      // 对应逻辑已写入 assistantMsg.showStaleFootnote / injectedWebSearchCount，MessageBubble 直接渲染

      // 如果搜索有结果 → 底部附上"搜索结果N条注入"摘要（不写入正式内容，只做一个 toast 提示）
      if (wasSearchMode && _webSearchCfg.webSearchEnabled && mounted) {
        final msg = searchHitCount == 0
            ? l.tr('searchResultEmpty')
            : l.tr('searchResultCount', args: {'count': '$searchHitCount'});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
        );
      }

      assistantMsg.content = fullResponse;
      _logger.verbose(
          '[Chat] AI response (${fullResponse.length} chars): ${fullResponse.substring(0, fullResponse.length > 500 ? 500 : fullResponse.length)}${fullResponse.length > 500 ? '...' : ''}',
          cat: LogCat.chat,
          tag: 'Chat');
      // v1.3.6：保存 token 用量
      assistantMsg.promptTokens =
          apiSvc.totalPromptTokens > 0 ? apiSvc.totalPromptTokens : null;
      assistantMsg.completionTokens = apiSvc.totalCompletionTokens > 0
          ? apiSvc.totalCompletionTokens
          : null;
      assistantMsg.totalTokens =
          apiSvc.totalAllTokens > 0 ? apiSvc.totalAllTokens : null;
      // 确保脚注标志同步（以防 streaming 期间被覆盖）
      assistantMsg.showStaleFootnote = willWarnStaleKnowledge;
      assistantMsg.injectedWebSearchCount = searchHitCount;
      await storage.saveMessage(assistantMsg);
      if (mounted) setState(() {});

      if (widget.conversation.title == 'New Chat' && _messages.length <= 3) {
        final title = text.length > 30 ? '${text.substring(0, 30)}...' : text;
        await storage.updateConversationTitle(widget.conversation.id, title);
      }
    } catch (e, st) {
      _logger.error(
          '[Chat] Stream failed: config=${_apiConfig?.name ?? 'null'}, model=${_apiConfig?.model ?? 'null'}',
          error: e,
          stack: st,
          cat: LogCat.chat,
          tag: 'Chat');
      final err = 'Error: $e';
      assistantMsg.content = err;
      // ===== v1.4.5：出错也强制保存（保证用户能看到出错前收到的内容已被覆盖为 Error 信息） =====
      await _throttledSaveAssistantContent(storage, assistantMsg, err,
          force: true);
      await storage.saveMessage(assistantMsg);
      // v1.6.8 修复 Bug#6：catch 内 setState 必须检查 mounted。
      // Bug#4 流式循环 setState 崩溃会被本 catch 接住，若这里再 setState 又抛
      // → 级联未捕获异常。改为只在 mounted 时 setState，避免级联。
      if (mounted) {
        setState(() {
          _messages.last.content = err;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isStreaming = false;
        });
      }
    }
  }

  void _stopGeneration() {
    context.read<ApiService>().stopGeneration();
    // v1.4.2 修复：停止按钮同时终止 ReAct 循环。
    // 之前只 stopGeneration()（只对 streamChat 的 _shouldStop 生效），
    // ReAct 循环走 completeChat（非流式）停不下来，导致按钮"点不动"。
    _reactLoopStopRequested = true;
    _logger.info('[Chat] Generation stopped by user',
        cat: LogCat.chat, tag: 'Chat');
  }

  /// 打开设置页（联网搜索配置）
  void _openSearchSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  List<ChatMessage> _limitedContext(List<ChatMessage> messages) {
    // v1.4.1：上下文"自动"模式 → 不截断，全量发送；关闭自动才用细化上限
    if (widget.conversation.contextAuto) return messages;
    final limit = widget.conversation.contextLimit;
    if (limit <= 0 || messages.length <= limit) return messages;
    return messages.sublist(messages.length - limit);
  }

  ApiConfig get _conversationApiConfig {
    final base = (_currentSessionModel ?? _apiConfig)!;
    return base.copyWith(
      name: base.name,
      model: base.model,
      baseUrl: base.baseUrl,
      apiKey: base.apiKey,
      systemPrompt: base.systemPrompt,
      maxTokens: base.maxTokens,
      temperature: widget.conversation.temperature,
      topP: widget.conversation.topP,
    );
  }

  Future<void> _showConversationSettings() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    int contextLimit = widget.conversation.contextLimit;
    double temperature = widget.conversation.temperature;
    double topP = widget.conversation.topP;
    bool enable20sCheck = widget.conversation.enable20sCheck;
    bool contextAuto = widget.conversation.contextAuto;
    bool autoCompress = widget.conversation.autoCompress;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isZh ? '对话设置' : 'Chat Settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // v1.4.1：上下文第一行是"自动"开关；关掉自动 → 显示细化手动上限
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '上下文上限' : 'Context limit'),
                  subtitle: Text(contextAuto
                      ? (isZh ? '自动：全量发送所有历史消息' : 'Auto: send the full history')
                      : (isZh
                          ? '细化：只发送最近 $contextLimit 条消息'
                          : 'Manual: send only the last $contextLimit messages')),
                  value: contextAuto,
                  onChanged: (value) =>
                      setDialogState(() => contextAuto = value),
                ),
                if (!contextAuto) ...[
                  Text(isZh
                      ? '上下文上限：$contextLimit 条消息'
                      : 'Context limit: $contextLimit messages'),
                  Slider(
                    value: contextLimit.toDouble(),
                    min: 2,
                    max: 100,
                    divisions: 49,
                    onChanged: (value) =>
                        setDialogState(() => contextLimit = value.round()),
                  ),
                ],
                // v1.4.1：自动压缩开关（上下文过长时把旧消息压成摘要）
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '自动压缩' : 'Auto compress'),
                  subtitle: Text(isZh
                      ? '上下文过长时自动把旧消息压缩成摘要（也可在右上角菜单手动压缩）'
                      : 'Automatically compress old messages into a summary when context is too long'),
                  value: autoCompress,
                  onChanged: (value) =>
                      setDialogState(() => autoCompress = value),
                ),
                Text(isZh
                    ? '温度：${temperature.toStringAsFixed(1)}'
                    : 'Temp: ${temperature.toStringAsFixed(1)}'),
                Slider(
                  value: temperature,
                  min: 0,
                  max: 2,
                  divisions: 20,
                  onChanged: (value) =>
                      setDialogState(() => temperature = value),
                ),
                Text(isZh
                    ? 'Top P：${topP.toStringAsFixed(2)}'
                    : 'Top P: ${topP.toStringAsFixed(2)}'),
                Slider(
                  value: topP,
                  min: 0.05,
                  max: 1,
                  divisions: 19,
                  onChanged: (value) => setDialogState(() => topP = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '20 秒防卡壳' : '20s anti-stall'),
                  subtitle: Text(isZh
                      ? '默认开启，每 20 秒让 AI 自检是否继续'
                      : 'On by default; AI self-checks every 20s whether to continue'),
                  value: enable20sCheck,
                  onChanged: (value) =>
                      setDialogState(() => enable20sCheck = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(isZh ? '取消' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(isZh ? '保存' : 'Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    widget.conversation.contextLimit = contextLimit;
    widget.conversation.temperature = temperature;
    widget.conversation.topP = topP;
    widget.conversation.enable20sCheck = enable20sCheck;
    widget.conversation.contextAuto = contextAuto;
    widget.conversation.autoCompress = autoCompress;
    await _storage.saveConversation(widget.conversation);
    if (mounted) setState(() => _enable20sCheck = enable20sCheck);
  }

  // ==========================================================================
  // v1.4.1：上下文压缩（三点菜单手动点击；对话设置里也可开"自动压缩"）
  // 思路：旧消息交给 LLM 总结成一条摘要插到历史顶部，旧消息从库里删除。
  // 自动压缩（ReAct 循环内）只在内存里压，不写库。
  // ==========================================================================
  Future<void> _compressContext() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    if (_apiConfig == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isZh
              ? '请先连接 AI 密钥再压缩上下文'
              : 'Configure an API key before compressing'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }
    if (_isStreaming) return; // AI 正在思考时不压缩
    if (_messages.length <= 4) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              isZh ? '消息还不够多，暂时不用压缩' : 'Not enough messages to compress yet'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }

    // 保留最近 4 条，压缩之前的全部
    final oldMsgs = _messages.sublist(0, _messages.length - 4).toList();
    final apiSvc = context.read<ApiService>();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isZh ? '正在压缩上下文…' : 'Compressing context...'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ));
    }

    try {
      final summary = await _summarizeMessages(apiSvc, oldMsgs);
      if (summary.isEmpty) throw Exception('AI 返回的摘要为空');

      // 删掉旧消息，把摘要插到历史顶部（createdAt 用被压缩的最早一条的时间）
      for (final m in oldMsgs) {
        await _storage.deleteMessage(m.id);
      }
      final summaryMsg = ChatMessage(
        id: const Uuid().v4(),
        conversationId: widget.conversation.id,
        role: MessageRole.user,
        content: isZh
            ? '【上下文压缩摘要】\n$summary'
            : '[Context compression summary]\n$summary',
        createdAt: oldMsgs.first.createdAt,
      );
      await _storage.saveMessage(summaryMsg);
      _logger.info(
          '[Chat] Manually compressed context: ${oldMsgs.length} msgs → 1 summary',
          tag: 'Chat');
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isZh
              ? '压缩完成：${oldMsgs.length} 条旧消息已压缩成 1 条摘要'
              : 'Compressed: ${oldMsgs.length} old messages → 1 summary'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      _logger.error('[Chat] Compress context failed',
          error: e, cat: LogCat.chat, tag: 'Chat');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isZh ? '压缩失败：$e' : 'Compress failed: $e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  /// v1.4.2：把一批消息交给 LLM 总结成结构化摘要
  /// 输出包含：关键决定、用户诉求、AI 结论、未完成事项
  Future<String> _summarizeMessages(
      ApiService apiSvc, List<ChatMessage> msgs) async {
    final lines = msgs.map((m) {
      final who = m.role == MessageRole.user ? '用户' : 'AI';
      final c = m.content.length > 800
          ? '${m.content.substring(0, 800)}…'
          : m.content;
      return '$who: $c';
    }).join('\n');
    final resp = await apiSvc.completeChat(
      config: _conversationApiConfig.copyWith(temperature: 0.2),
      messages: [
        ChatMessage.create(
          conversationId: widget.conversation.id,
          role: MessageRole.system,
          content: '''你是专业的对话上下文压缩器。请把下面的对话历史压缩成一段结构化的摘要，格式如下：

## 📋 关键决定
- 列出对话中做出的重要决定和选择

## 💬 用户诉求
- 列出用户表达的核心需求和偏好

## ✅ AI 结论
- 列出 AI 给出的重要结论和答案

## 📌 未完成事项
- 列出还需要处理的事情（如果有）

要求：
1. 每个部分用 1-3 条要点，简洁明了
2. 不超过 400 字
3. 只输出摘要正文，不要输出任何其他内容''',
        ),
        ChatMessage.create(
          conversationId: widget.conversation.id,
          role: MessageRole.user,
          content: lines,
        ),
      ],
      timeout: const Duration(seconds: 60),
    );
    return _extractFirstAnswer(resp);
  }

  // ==========================================================================
  // v1.4.2：通用文件下载（支持视频/图片/文档等任何 URL）
  // ==========================================================================

  /// 通用下载对话框：用户输入 URL → 下载任意文件
  Future<void> _showGenericDownloadDialog() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final urlCtrl = TextEditingController();
    final fileNameCtrl = TextEditingController();
    bool isDownloading = false;
    double progress = 0;
    String status = '';
    String? downloadedPath;
    String? taskId; // v1.5.0：下载取消用

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setModal) {
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 20),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                const Icon(Icons.download_rounded),
                const SizedBox(width: 8),
                Expanded(child: Text(isZh ? '下载任意文件' : 'Download any file')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: urlCtrl,
                  decoration: InputDecoration(
                    labelText: isZh ? '文件 URL' : 'File URL',
                    hintText: 'https://example.com/video.mp4',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.link),
                  ),
                  enabled: !isDownloading,
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: fileNameCtrl,
                  decoration: InputDecoration(
                    labelText: isZh ? '文件名（可选）' : 'File name (optional)',
                    hintText: isZh
                        ? '留空则自动从 URL 推断'
                        : 'Leave empty to infer from URL',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.insert_drive_file),
                  ),
                  enabled: !isDownloading,
                ),
                const SizedBox(height: 16),
                if (isDownloading) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      minHeight: 10,
                      value: progress > 0 ? progress : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status.isEmpty
                        ? (isZh ? '下载中…' : 'Downloading...')
                        : status,
                    style: Theme.of(ctx2).textTheme.bodySmall,
                  ),
                ],
                if (downloadedPath != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx2).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(isZh ? '✅ 下载成功' : '✅ Downloaded',
                            style: TextStyle(
                                color: Theme.of(ctx2)
                                    .colorScheme
                                    .onPrimaryContainer,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text(downloadedPath!,
                            style: Theme.of(ctx2).textTheme.bodySmall,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
                if (!isDownloading && downloadedPath == null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx2).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isZh
                          ? '💡 支持视频/图片/音频/文档等任何 URL\n下载后按类型自动分类保存'
                          : '💡 Works with any URL: video/image/audio/document\nDownloads are auto-sorted by type',
                      style: Theme.of(ctx2).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            actions: [
              if (!isDownloading)
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(isZh ? '取消' : 'Cancel'),
                ),
              if (downloadedPath != null)
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(isZh
                              ? '已保存：$downloadedPath'
                              : 'Saved: $downloadedPath')),
                    );
                  },
                  icon: const Icon(Icons.check),
                  label: Text(isZh ? '完成' : 'Done'),
                ),
              if (!isDownloading && downloadedPath == null)
                FilledButton.icon(
                  onPressed: () async {
                    final url = urlCtrl.text.trim();
                    if (url.isEmpty || !url.startsWith('http')) {
                      setModal(() {
                        status =
                            isZh ? '请输入有效的 URL' : 'Please enter a valid URL';
                      });
                      return;
                    }
                    // v1.5.0：生成 taskId 便于取消按钮
                    taskId = 'dialog_${DateTime.now().millisecondsSinceEpoch}';
                    setModal(() {
                      isDownloading = true;
                      progress = 0;
                      status = isZh ? '连接中…' : 'Connecting...';
                    });
                    try {
                      final dlSvc = context.read<AppDownloadService>();
                      final result = await dlSvc.downloadFileFromUrl(
                        url: url,
                        fileName: fileNameCtrl.text.trim().isEmpty
                            ? null
                            : fileNameCtrl.text.trim(),
                        taskId: taskId,
                        onProgress: (received, total) {
                          setModal(() {
                            progress = total > 0 ? received / total : 0;
                            status =
                                '${_fmtBytes(received)} / ${total > 0 ? _fmtBytes(total) : (isZh ? "未知" : "unknown")}';
                          });
                        },
                      );
                      setModal(() {
                        isDownloading = false;
                        downloadedPath = result['path'] as String;
                        status = isZh ? '完成' : 'Done';
                      });
                    } catch (e) {
                      setModal(() {
                        isDownloading = false;
                        status = isZh ? '❌ 下载失败：$e' : '❌ Download failed: $e';
                      });
                      if (ctx2.mounted) {
                        ScaffoldMessenger.of(ctx2).showSnackBar(
                          SnackBar(
                              content: Text(
                                  isZh ? '下载失败：$e' : 'Download failed: $e')),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.download),
                  label: Text(isZh ? '开始下载' : 'Start download'),
                ),
              if (isDownloading)
                TextButton.icon(
                  onPressed: () {
                    // v1.5.0：下载中显示取消按钮（taskId 在开始下载时已赋值）
                    context.read<AppDownloadService>().cancelDownload(taskId!);
                  },
                  icon: const Icon(Icons.cancel_outlined),
                  label: Text(isZh ? '取消下载' : 'Cancel download'),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 格式化字节数
  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// v1.4.2：ReAct 循环中的通用下载（AI 触发）
  Future<void> _reactGenericDownload(
      String url, ChatMessage assistantMsg) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final dlSvc = context.read<AppDownloadService>();
    // v1.5.0：生成 taskId，便于用户从 SnackBar 取消
    final taskId = 'react_${DateTime.now().millisecondsSinceEpoch}';

    // 先更新 AI 回复内容
    assistantMsg.content = '📥 正在为你下载文件...\n\nURL: $url';
    if (mounted) setState(() {});

    // v1.5.0：弹一个 SnackBar 让用户能取消
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isZh ? '📥 正在下载...' : '📥 Downloading...'),
          duration: const Duration(days: 1),
          action: SnackBarAction(
            label: isZh ? '取消' : 'Cancel',
            onPressed: () => dlSvc.cancelDownload(taskId),
          ),
        ),
      );
    }

    try {
      final result = await dlSvc.downloadFileFromUrl(
        url: url,
        taskId: taskId,
        onProgress: (received, total) {
          if (mounted) {
            final pct =
                total > 0 ? (received / total * 100).toStringAsFixed(1) : '...';
            assistantMsg.content =
                '📥 正在下载... ${_fmtBytes(received)} / ${total > 0 ? _fmtBytes(total) : "?"} ($pct%)';
            setState(() {});
          }
        },
      );

      final path = result['path'] as String;
      final fileName = result['fileName'] as String;
      final size = result['size'] as int;
      final contentType = result['contentType'] as String;

      assistantMsg.content = '''✅ 下载完成！

📁 文件名：$fileName
📦 大小：${_fmtBytes(size)}
🔤 类型：$contentType
📂 保存位置：$path''';

      assistantMsg.addReasoning(ReasoningStep(
        'answer',
        '文件已成功下载到设备。',
      ));

      // v1.7.5: APK 下载完成后调用 MobSF 安全审查
      // v1.7.11: 新增 VirusTotal 云端查毒（APK + 文档/EXE/压缩包）
      try {
        final storage = context.read<StorageService>();
        final cfg = await storage.getWebSearchConfig();
        if (path.toLowerCase().endsWith('.apk')) {
          // MobSF 审查
          if (cfg.enableApkSecurityScan && cfg.mobsfEndpoint.isNotEmpty) {
            assistantMsg.content += '\n\n🔍 正在进行 MobSF 安全审查...';
            if (mounted) setState(() {});

            final scanResult = await SecurityScanService.scanApk(
              mobsfEndpoint: cfg.mobsfEndpoint,
              apkFilePath: path,
              apkName: fileName,
              mobsfApiKey: cfg.mobsfApiKey, // v1.7.11 P0 修复
            );

            if (scanResult.success) {
              final riskLabel = isZh ? scanResult.riskLabelZh : scanResult.riskLabelEn;
              assistantMsg.content += '\n🛡️ MobSF 审查：$riskLabel (${scanResult.riskScore}/100)';
              if (scanResult.findings.isNotEmpty) {
                assistantMsg.content += '\n⚠️ 发现 ${scanResult.findings.length} 个问题';
              }
              if (!scanResult.safeToInstall) {
                assistantMsg.content += '\n❌ 此 APK 存在安全风险，建议谨慎安装';
              }
            } else {
              assistantMsg.content += '\n⚠️ MobSF 审查失败：${scanResult.errorMessage}';
            }
          }
          // VirusTotal 查毒（APK 也查）
          if (cfg.enableVirusTotalScan && cfg.virusTotalApiKey.isNotEmpty) {
            assistantMsg.content += '\n\n🔍 正在进行 VirusTotal 查毒...';
            if (mounted) setState(() {});

            final vtResult = await SecurityScanService.scanFileWithVirusTotal(
              apiKey: cfg.virusTotalApiKey,
              filePath: path,
              fileName: fileName,
            );

            if (vtResult.success) {
              final riskLabel = isZh ? vtResult.riskLabelZh : vtResult.riskLabelEn;
              assistantMsg.content += '\n🛡️ VirusTotal：$riskLabel (${vtResult.riskScore}/100)';
              for (final f in vtResult.findings) {
                assistantMsg.content += '\n  • ${f.title}';
              }
              if (!vtResult.safeToInstall) {
                assistantMsg.content += '\n❌ VirusTotal 检测到风险，建议谨慎';
              }
            } else {
              assistantMsg.content += '\n⚠️ VirusTotal 查毒失败：${vtResult.errorMessage}';
            }
          }
        } else if (cfg.enableVirusTotalScan && cfg.virusTotalApiKey.isNotEmpty &&
            _isScanableFile(path)) {
          // v1.7.11: 非 APK 文件（文档/EXE/压缩包）也走 VirusTotal 查毒
          assistantMsg.content += '\n\n🔍 正在进行 VirusTotal 查毒...';
          if (mounted) setState(() {});

          final vtResult = await SecurityScanService.scanFileWithVirusTotal(
            apiKey: cfg.virusTotalApiKey,
            filePath: path,
            fileName: fileName,
          );

          if (vtResult.success) {
            final riskLabel = isZh ? vtResult.riskLabelZh : vtResult.riskLabelEn;
            assistantMsg.content += '\n🛡️ VirusTotal：$riskLabel (${vtResult.riskScore}/100)';
            for (final f in vtResult.findings) {
              assistantMsg.content += '\n  • ${f.title}';
            }
          } else {
            assistantMsg.content += '\n⚠️ VirusTotal 查毒失败：${vtResult.errorMessage}';
          }
        }
      } catch (e) {
        assistantMsg.content += '\n⚠️ 安全审查失败：$e';
      }

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isZh ? '下载完成：$fileName' : 'Downloaded: $fileName'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
      assistantMsg.content = '''❌ 下载失败

错误信息：$e

可能的原因：
1. URL 无效或文件已删除
2. 服务器需要认证或禁止直链下载
3. 网络连接问题

建议：尝试使用"下载文件"功能手动输入 URL，或让我搜索可下载的替代链接。''';

      assistantMsg.addReasoning(ReasoningStep(
        'answer',
        '下载失败，需要用户检查 URL 或换一个链接。',
      ));

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isZh ? '下载失败：$e' : 'Download failed: $e')),
        );
      }
    }
  }

  // ==========================================================================
  // UI
  // ==========================================================================
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final webEnabled = _webSearchCfg.webSearchEnabled;
    // v1.6.9 build42 修复问题1/4：监听插件启用状态，使输入框 🌐/🧠 随插件开关实时刷新。
    final registry = context.watch<PluginRegistry>();
    final searchPluginOn = registry.isEnabled(PluginRegistry.kSearchPluginId);
    final selfCheckPluginOn =
        registry.isEnabled(PluginRegistry.kSelfCheckPluginId);

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_apiConfig == null) {
      return Scaffold(
        // v1.3.4：没连 AI 时左上角显示"内置"
        appBar: AppBar(title: Text(isZh ? '内置' : 'Built-in')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.chat, size: 64, color: Colors.orange),
                const SizedBox(height: 16),
                Text(l.tr('apiConfigNotFound'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 24),
                Text(
                  isZh
                      ? '💡 没有 API Key 也能先体验哦！试试在输入框里说：\n'
                          '"帮我下载微信"\n"download telegram"'
                      : '💡 No API key? You can still try it! Type:\n'
                          '"download WeChat"\n"download telegram"',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l.tr('goBack')),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        // v1.3.4：左上角显示当前使用的模型名，而不是对话标题
        // 没连 AI（_apiConfig==null）显示"内置"，便于用户一眼看出当前来源
        title: Text(
          (_apiConfig != null && _apiConfig!.model.isNotEmpty)
              ? _apiConfig!.model
              : isZh
                  ? '内置'
                  : 'Built-in',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'pluginManager') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PluginManagementScreen()),
                );
              } else if (value == 'settings') {
                await _showConversationSettings();
              } else if (value == 'compress') {
                await _compressContext();
              } else if (value == 'download') {
                await _showGenericDownloadDialog();
              } else if (value == 'clear') {
                final storage = context.read<StorageService>();
                await storage
                    .deleteMessagesByConversation(widget.conversation.id);
                _loadData();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'pluginManager',
                child: Row(
                  children: [
                    const Icon(Icons.extension),
                    const SizedBox(width: 8),
                    Text(isZh ? '🧩 插件管理' : '🧩 Plugin Manager'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    const Icon(Icons.tune),
                    const SizedBox(width: 8),
                    Text(isZh ? '对话设置' : 'Chat Settings'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'compress',
                child: Row(
                  children: [
                    const Icon(Icons.compress),
                    const SizedBox(width: 8),
                    Text(isZh ? '压缩上下文' : 'Compress Context'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'download',
                child: Row(
                  children: [
                    const Icon(Icons.download_rounded),
                    const SizedBox(width: 8),
                    Text(isZh ? '下载文件' : 'Download File'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    const Icon(Icons.clear_all),
                    const SizedBox(width: 8),
                    Text(l.tr('clearMessages')),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.chat_bubble_outline,
                              size: 64,
                              color: Theme.of(context).colorScheme.outline),
                          const SizedBox(height: 16),
                          Text(
                              l.tr('startChattingWith',
                                  args: {'model': _apiConfig!.model}),
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 24),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              isZh
                                  ? '💡 也可以试试：\n'
                                      '　• 帮我下载微信\n'
                                      '　• download telegram\n\n'
                                      '🌐 点击输入框左侧按钮可切换"联网搜索"模式，\n'
                                      '    搜索模式下回答前会先上网查最新信息。'
                                  : '💡 You can also try:\n'
                                      '  • download WeChat\n'
                                      '  • download telegram\n\n'
                                      '🌐 Tap the button left of the input box to toggle web search mode.\n'
                                      '    In search mode, answers are based on fresh web results.',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final isLast = index == _messages.length - 1;
                      final isStreaming = isLast && _isStreaming;
                      final displayCfg = _currentSessionModel ?? _apiConfig;
                      return MessageBubble(
                        message: msg,
                        isStreaming: isStreaming,
                        modelName:
                            (displayCfg != null && displayCfg.model.isNotEmpty)
                                ? displayCfg.model
                                : isZh
                                    ? '内置'
                                    : 'Built-in',
                      );
                    },
                  ),
          ),
          ChatInput(
            controller: _inputController,
            onSend: _sendMessage,
            onStop: _stopGeneration,
            isGenerating: _isStreaming,
            searchEnabled: webEnabled && searchPluginOn,
            searchMode: _searchMode,
            onToggleSearch: () async {
              // build 11+：切换后立即持久化（常驻，不再发完就 reset）
              await _saveSearchToggle(!_searchMode);
            },
            onOpenSearchSettings: _openSearchSettings,
            onLongPressOpenSettings: _openSearchSettings,
            reactRounds: _webSearchCfg.reactMaxRounds,
            reactLevelLabel: _webSearchCfg.reactLevelLabel,
            reactEnabled: _webSearchCfg.reactEnabled && selfCheckPluginOn,
            onCycleReactLevel: _cycleReactLevel,
            // v1.3.3 新增
            reactAutoMode: _webSearchCfg.reactAutoMode,
            pendingFollowupCount: pendingFollowupCount,
            // v1.6.0：🤖 模型选择
            availableConfigs: _apiConfigs,
            currentConfig: _currentSessionModel,
            onModelChanged: (newCfg) {
              setState(() {
                _currentSessionModel = newCfg;
              });
            },
            // v1.3.6：📎 附件
            pendingAttachments: _pendingAttachments,
            onPickAttachment: _pickAttachment,
            onRemoveAttachment: _removeAttachment,
          ),
        ],
      ),
    );
  }

  /// v1.7.11: 判断文件是否值得 VirusTotal 查毒
  /// 排除媒体文件（图片/视频/音频），包含可执行文件/文档/压缩包
  static bool _isScanableFile(String path) {
    final ext = path.toLowerCase().split('.').last;
    const scanable = {
      'exe', 'msi', 'apk', 'ipa', 'deb', 'rpm', 'dmg', 'app',
      'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz',
      'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
      'jar', 'war', 'class', 'py', 'sh', 'bat', 'ps1',
      'dll', 'so', 'dylib', 'bin',
    };
    return scanable.contains(ext);
  }

  @override
  void dispose() {
    // v1.3.4：移除 storage listener，避免内存泄漏
    _storage.removeListener(_storageListener);
    _scrollController.dispose();
    _inputController.dispose();
    super.dispose();
  }
}

// ==========================================================================
// v1.4.2：文件来源卡片 widget
// ==========================================================================

class _FileSourceCard extends StatelessWidget {
  final Map<String, String> source;
  final String typeLabel;
  final VoidCallback onTap;

  const _FileSourceCard({
    required this.source,
    required this.typeLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final name = source['sourceName'] ?? (isZh ? '未知' : 'Unknown');
    final domain = source['sourceDomain'] ?? '';
    final url = source['downloadUrl'] ?? '';
    final snippet = source['snippet'] ?? '';

    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.insert_drive_file,
                      size: 20, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      typeLabel,
                      style: TextStyle(
                        color: colorScheme.onPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (domain.isNotEmpty)
                Text(
                  domain,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (snippet.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  snippet,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.download_rounded,
                      size: 16, color: colorScheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    isZh ? '点击下载' : 'Download',
                    style: TextStyle(
                      color: colorScheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (url.isNotEmpty)
                    Text(
                      _shortenUrl(url),
                      style: Theme.of(context).textTheme.labelSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _shortenUrl(String url) {
    if (url.length <= 50) return url;
    return '${url.substring(0, 47)}...';
  }
}
