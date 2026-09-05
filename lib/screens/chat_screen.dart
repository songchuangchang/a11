import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/plugin_hint_config.dart';
import '../models/web_search_config.dart';
import '../plugins/plugin_context.dart';
import '../plugins/plugin_interface.dart';
import '../plugins/plugin_registry.dart';
import '../services/api_service.dart';
import '../services/app_download_service.dart';
import '../services/attachment_service.dart';
import '../services/conversation_summary_service.dart';
import '../services/logger_service.dart';
import '../services/plugin_prompt_catalog.dart';
import '../services/react_parser.dart';
import '../services/security_scan_service.dart';
import '../services/storage_service.dart';
import '../services/web_search_service.dart';
import '../widgets/app_source_selector.dart';
import '../widgets/download_confirm_dialog.dart';
import '../widgets/download_progress_widget.dart';
import '../widgets/chat_input.dart';
import '../widgets/chat_input_actions.dart';
import '../widgets/chat_input_config.dart';
import '../widgets/chat_screen_widgets.dart';
import '../widgets/message_bubble.dart';
import 'plugin_management_screen.dart';
import 'settings_screen.dart';
import 'web_search_settings_screen.dart';

part 'chat_screen_context.dart';
part 'chat_screen_download.dart';
part 'chat_screen_message.dart';
part 'chat_screen_react.dart';


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
  late final VoidCallback _inputListener;
  String get _draftPrefsKey => 'chat_draft_${widget.conversation.id}';

  // v1.7.18：ChatInput v2（5 参数重构）需要外部 FocusNode
  final FocusNode _inputFocus = FocusNode();

  // ===== v1.7.22：撤回重试系统（v1.7.26 (E3) 起版本快照持久化到
  // message_versions 表，此处仅作为会话内缓存，重启后由 _loadData 恢复）=====
  final Map<String, List<RetryVersion>> _retryVersionStore = {};
  final Map<String, int> _activeRetryVersionIndex = {};

  // ===== v1.7.21 P1-2：发送前 API 连接快速自检（30 秒缓存，避免每条消息都测）=====
  DateTime? _lastApiTestTime;
  bool _lastApiTestOk = false;

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

  // ===== v1.7.17：🔌 插件提示三态开关（off / manual / auto）=====
  /// 状态存 SharedPreferences（避免为一个小配置动 DB schema）。
  /// 旧键迁移（plugin_hint_enabled→auto / off，plugin_hint_items→extraHints）
  /// 已在 PluginHintConfig.load 内实现。
  PluginHintConfig _pluginHintConfig = const PluginHintConfig();

  // ===== v1.3.3 build 13 新增状态 =====
  /// 思考循环期间用户中途插话的消息队列（FIFO）
  /// _runReActLoop 每轮 LLM 返回后会 drain 这个队列到 workingMessages
  final List<String> _pendingFollowupMessages = [];
  int get pendingFollowupCount => _pendingFollowupMessages.length;

  /// 是否启用"每 20 秒确认一次"防卡壳机制（用户用 ⏱️ 按钮切换）
  bool _enable20sCheck = true;

  /// 用户在 20 秒确认弹窗里点了"终止输出" → ReAct 循环检测到后立即结束
  bool _reactLoopStopRequested = false;

  /// v1.7.17：detail 标签注入去重（key=plugin:xxx / mcp:xxx.yyy / skill:xxx）。
  /// 单次 ReAct 循环内同一详情只注入一次，防止上下文膨胀。
  final Set<String> _injectedDetails = {};

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

  /// v1.7.25：从 conversation 生成思考程度标签（用于输入框 tooltip）
  String get _conversationReactLevelLabel {
    final c = widget.conversation;
    if (c.reactAutoMode) return '自动 Auto';
    if (c.reactMaxRounds <= 0) return '关 Off';
    if (c.reactMaxRounds <= 2) return '低 Low';
    if (c.reactMaxRounds <= 5) return '中 Medium';
    return '高 High';
  }

  /// 🧠 思考强度（每对话独有）0.0=默认(自动) 0.1–1.0 连续小数
  Future<void> _saveReasoningEffort(double e) async {
    final storage = context.read<StorageService>();
    widget.conversation.reasoningEffort = e;
    await storage.saveConversation(widget.conversation);
    if (!mounted) return;
    setState(() {});
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(isZh
          ? '🧠 思考强度：${reasoningEffortLabel(e, true)}'
          : '🧠 Reasoning effort: ${reasoningEffortLabel(e, false)}'),
      duration: const Duration(milliseconds: 900),
      behavior: SnackBarBehavior.floating,
      width: 240,
    ));
  }

  @override
  void initState() {
    super.initState();
    // v1.3.4：缓存 storage 引用 + 注册 listener，设置页改配置后能实时刷新
    _storage = context.read<StorageService>();
    _storageListener = _onStorageChanged;
    _storage.addListener(_storageListener);
    _inputListener = _saveDraft;
    _inputController.addListener(_inputListener);
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

  void _saveDraft() {
    final text = _inputController.text;
    SharedPreferences.getInstance().then((prefs) {
      if (text.isEmpty) {
        prefs.remove(_draftPrefsKey);
      } else {
        prefs.setString(_draftPrefsKey, text);
      }
    });
  }

  Future<void> _loadData() async {
    final messages = await _storage.getMessages(widget.conversation.id);
    final config = await _storage.getApiConfig(widget.conversation.apiConfigId);
    final allConfigs = await _storage.getApiConfigs();
    final webCfg = await _storage.getWebSearchConfig();
    // v1.7.17：读 🔌 插件提示三态配置（旧键迁移已在 load 内实现）
    final hintConfig = await PluginHintConfig.load();
    final prefs = await SharedPreferences.getInstance();
    final draft = prefs.getString(_draftPrefsKey) ?? '';
    // v1.7.26 (E3)：恢复持久化的重试版本快照（此前仅内存，重启后版本切换丢失）
    final versionMap = await _storage.loadMessageVersions();
    if (mounted) {
      setState(() {
        _pluginHintConfig = hintConfig;
        _messages = messages;
        _apiConfig = config;
        _apiConfigs = allConfigs;
        _currentSessionModel =
            _apiConfig ?? (allConfigs.isNotEmpty ? allConfigs.first : null);
        _webSearchCfg = webCfg;
        _enable20sCheck = widget.conversation.enable20sCheck;
        _searchMode = webCfg.persistentWebSearchToggle;
        _retryVersionStore
          ..clear()
          ..addAll(versionMap);
        if (draft.isNotEmpty && _inputController.text.isEmpty) {
          _inputController.value = TextEditingValue(
            text: draft,
            selection: TextSelection.collapsed(offset: draft.length),
          );
        }
        for (final e in _retryVersionStore.entries) {
          _activeRetryVersionIndex[e.key] = e.value.length;
        }
        _isLoading = false;
      });
      // v1.3.4：启动时同步详细日志模式
      LoggerService.instance.verboseEnabled = webCfg.verboseLogging;
      _scrollToBottom();
    }
  }


  /// v1.7.17：非 ReAct 普通聊天路径的 🔌 提示文本。
  /// - off：空串（不注入）
  /// - manual/auto：注入 extraHints
  /// - auto：额外注入 enabled MCP/Skill 的小目录摘要（一行一个，不引入 detail 协议）
  String _buildNormalChatPluginHint(PluginRegistry registry) {
    final cfg = _pluginHintConfig;
    if (cfg.mode == PluginHintMode.off) return '';
    final parts = <String>[];
    if (cfg.extraHints.isNotEmpty) parts.add(cfg.extraHints.join('\n'));
    if (cfg.mode == PluginHintMode.auto) {
      final entries = <String>[];
      for (final p in registry.plugins) {
        if (!registry.isEnabled(p.metadata.id)) continue;
        final m = p.metadata;
        if (m.kind == PluginKind.mcpRemote) {
          entries.add('- MCP ${m.name} (${m.id})');
        } else if (m.kind == PluginKind.declarative &&
            p.source != PluginSource.system) {
          entries.add('- Skill ${m.name} (${m.id})');
        }
      }
      if (entries.isNotEmpty) {
        parts.add('已启用插件目录：\n${entries.join('\n')}');
      }
    }
    return parts.join('\n\n');
  }

  /// v1.7.17：手动模式下实际生效的勾选数（selectedIds ∩ 已启用插件 id）。
  int _effectiveManualSelectedCount(PluginRegistry registry) {
    if (_pluginHintConfig.mode != PluginHintMode.manual) return 0;
    final enabledIds = registry.plugins
        .where((p) => registry.isEnabled(p.metadata.id))
        .map((p) => p.metadata.id)
        .toSet();
    return _pluginHintConfig.selectedIds.where(enabledIds.contains).length;
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

  /// 打开设置页（联网搜索配置）
  void _openSearchSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
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
      return NoApiKeyView(
        l: l,
        isZh: isZh,
        onBack: () => Navigator.pop(context),
      );
    }

    return Scaffold(
      appBar: AppBar(
        // v1.7.21 P0-2：标题可自定义（点击编辑）；v1.7.20：首条消息后自动设标题
        title: GestureDetector(
          onTap: () => _editConversationTitle(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.conversation.title,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.edit_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
        actions: [
          ChatAppBarMenu(
            l: l,
            isZh: isZh,
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
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: EmptyChatHint(
                      l: l,
                      isZh: isZh,
                      model: _apiConfig!.model,
                      onPromptTap: (text) {
                        _inputController.text = text;
                        _inputFocus.requestFocus();
                      },
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
                      // v1.7.22：撤回 / 重试 / 版本切换回调（闭包调用 extension 成员）
                      final canRetry =
                          msg.role == MessageRole.assistant && !_isStreaming;
                      // v1.7.26 (E6)：按消息 id 稳定 Key——重试/撤回列表重建时避免
                      // Flutter 复用旧元素状态导致滚动位置/动画错乱
                      return MessageBubble(
                        key: ValueKey(msg.id),
                        message: msg,
                        isStreaming: isStreaming,
                        modelName:
                            (displayCfg != null && displayCfg.model.isNotEmpty)
                                ? displayCfg.model
                                : isZh
                                    ? '内置'
                                    : 'Built-in',
                        onRetry: canRetry ? () => _retryMessage(msg) : null,
                        retryVersionCount: _computeRetryVersionCount(msg),
                        retryVersionIndex: _computeRetryVersionIndex(msg),
                        onSwitchVersion: canRetry
                            ? (direction) => _switchRetryVersion(msg, direction)
                            : null,
                        onRollback: (msg.role == MessageRole.user &&
                                !_isStreaming)
                            ? () => _rollbackMessage(msg)
                            : null,
                      );
                    },
                  ),
          ),
          ChatInput(
            config: ChatInputConfig(
              searchMode: _searchMode,
              searchEnabled: webEnabled && searchPluginOn,
              reactRounds: widget.conversation.reactMaxRounds,
              reactLevelLabel: _conversationReactLevelLabel,
              reactEnabled:
                  widget.conversation.reactEnabled && selfCheckPluginOn,
              reactAutoMode: widget.conversation.reactAutoMode,
              reasoningEffort: widget.conversation.reasoningEffort,
              pluginHintMode: _pluginHintConfig.mode,
              pluginHintManualCount: _effectiveManualSelectedCount(registry),
              availableConfigs: _apiConfigs,
              currentConfig: _currentSessionModel,
              pendingAttachments: _pendingAttachments,
              pendingFollowupCount: pendingFollowupCount,
              isGenerating: _isStreaming,
            ),
            actions: ChatInputActions(
              onToggleSearch: () async {
                // build 11+：切换后立即持久化（常驻，不再发完就 reset）
                await _saveSearchToggle(!_searchMode);
              },
              onOpenSearchSettings: _openSearchSettings,
              // v1.7.18 需求7：🌐/🧠 长按分别跳转联网搜索 / 自主思考设置页
              onLongPressSearch: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const WebSearchSettingsScreen()),
                );
              },
              // v1.7.25：ReAct 全局设置页已删 → 长按 🧠 打开对话设置面板
              onLongPressReact: () => _showConversationSettings(),
              onReasoningEffortChanged: _saveReasoningEffort,
              onTogglePluginHint: _togglePluginHint,
              onEditPluginHint: _editPluginHint,
              onModelChanged: (newCfg) {
                setState(() {
                  _currentSessionModel = newCfg;
                });
              },
              onPickAttachment: _pickAttachment,
              onRemoveAttachment: _removeAttachment,
            ),
            controller: _inputController,
            focusNode: _inputFocus,
            onSend: () => _sendMessage(),
            onStop: () => _stopGeneration(),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // v1.7.16 修复：退页后停止 ReAct 循环 + 活跃流，避免后台继续烧 API / 写库
    _reactLoopStopRequested = true;
    try {
      context.read<ApiService>().stopGeneration();
    } catch (_) {
      // 树整体销毁时 context 可能已失效，忽略即可
    }
    // v1.3.4：移除 storage listener，避免内存泄漏
    _storage.removeListener(_storageListener);
    _inputController.removeListener(_inputListener);
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }
}
