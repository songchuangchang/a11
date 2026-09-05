import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../models/web_search_config.dart';
import '../models/api_config.dart';
import '../services/storage_service.dart';
import '../services/web_search_service.dart';
import '../services/app_download_service.dart';
import '../services/logger_service.dart';

class PluginContext {
  final List<ChatMessage> workingMessages;
  final StringBuffer answerBuffer;
  bool answered;
  bool mounted;
  final WebSearchConfig webSearchCfg;
  final ApiConfig? conversationApiConfig;
  final ChatMessage? userMsg;
  final ChatMessage assistantMsg;
  final String? rawResp;
  int totalSearchHits = 0;
  final StorageService? _storage;
  final WebSearchService? _webSearch;
  final AppDownloadService? _appDownload;
  final LoggerService? _logger;
  final BuildContext? _rootContext;
  final VoidCallback? _onRequestStop;
  final void Function(String text)? _onAppendReasoning;
  final void Function(String text)? _onAppendUserMessage;
  final void Function(String text, {int injectedWebSearchCount, bool forceSave})? _onFinalizeAnswer;
  final void Function(VoidCallback fn)? _onSetState;
  final Future<void> Function(int count)? _onSaveAssistantContent;
  final Future<String?> Function(String question, List<String> options)? _onShowAskUser;
  final Future<void> Function({
    required String userText,
    required String keyword,
    required List<String> altKeywords,
    required List<String> officialDomains,
    ChatMessage? existingUserMsg,
    ChatMessage? existingPlaceholder,
    String platform,
  })? _onPresentAppDownloadSources;
  final Future<void> Function({
    required String userText,
    required String query,
    String? fileType,
    ChatMessage? existingUserMsg,
    ChatMessage? existingPlaceholder,
  })? _onPresentFileSources;
  final Future<void> Function(String url, ChatMessage assistantMsg)? _onGenericDownload;
  final void Function(bool value)? _onAnsweredChanged;

  PluginContext({
    required this.workingMessages,
    required this.assistantMsg,
    required this.webSearchCfg,
    this.conversationApiConfig,
    this.userMsg,
    this.rawResp,
    StorageService? storage,
    WebSearchService? webSearch,
    AppDownloadService? appDownload,
    LoggerService? logger,
    StringBuffer? answerBuffer,
    this.answered = false,
    this.mounted = true,
    BuildContext? rootContext,
    VoidCallback? onRequestStop,
    void Function(String text)? onAppendReasoning,
    void Function(String text)? onAppendUserMessage,
    void Function(String text, {int injectedWebSearchCount, bool forceSave})? onFinalizeAnswer,
    void Function(VoidCallback fn)? onSetState,
    Future<void> Function(int count)? onSaveAssistantContent,
    Future<String?> Function(String question, List<String> options)? onShowAskUser,
    Future<void> Function({
      required String userText,
      required String keyword,
      required List<String> altKeywords,
      required List<String> officialDomains,
      ChatMessage? existingUserMsg,
      ChatMessage? existingPlaceholder,
      String platform,
    })? onPresentAppDownloadSources,
    Future<void> Function({
      required String userText,
      required String query,
      String? fileType,
      ChatMessage? existingUserMsg,
      ChatMessage? existingPlaceholder,
    })? onPresentFileSources,
    Future<void> Function(String url, ChatMessage assistantMsg)? onGenericDownload,
    void Function(bool value)? onAnsweredChanged,
  })  : answerBuffer = answerBuffer ?? StringBuffer(),
        _storage = storage,
        _webSearch = webSearch,
        _appDownload = appDownload,
        _logger = logger,
        _rootContext = rootContext,
        _onRequestStop = onRequestStop,
        _onAppendReasoning = onAppendReasoning,
        _onAppendUserMessage = onAppendUserMessage,
        _onFinalizeAnswer = onFinalizeAnswer,
        _onSetState = onSetState,
        _onSaveAssistantContent = onSaveAssistantContent,
        _onShowAskUser = onShowAskUser,
        _onPresentAppDownloadSources = onPresentAppDownloadSources,
        _onPresentFileSources = onPresentFileSources,
        _onGenericDownload = onGenericDownload,
        _onAnsweredChanged = onAnsweredChanged;

  StorageService get storage {
    assert(_storage != null, 'PluginContext.storage 未注入');
    return _storage!;
  }

  WebSearchService get webSearch {
    assert(_webSearch != null, 'PluginContext.webSearch 未注入');
    return _webSearch!;
  }

  AppDownloadService get appDownload {
    assert(_appDownload != null, 'PluginContext.appDownload 未注入');
    return _appDownload!;
  }

  LoggerService get logger {
    assert(_logger != null, 'PluginContext.logger 未注入');
    return _logger!;
  }

  void showSnackBar(String message, {bool error = false}) {
    if (!mounted) return;
    try {
      final ctx = _rootContext;
      if (ctx == null) return;
      ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Theme.of(ctx).colorScheme.error : null,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {}
  }

  void hideCurrentSnackBar() {
    if (!mounted) return;
    try {
      final ctx = _rootContext;
      if (ctx == null) return;
      ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
    } catch (_) {}
  }

  Future<T?> showDialogWidget<T>(Widget dialog, {bool barrierDismissible = true}) async {
    if (!mounted) return null;
    try {
      final ctx = _rootContext;
      if (ctx == null) return null;
      return await Navigator.of(ctx).push<T>(
        DialogRoute<T>(
          context: ctx,
          builder: (_) => dialog,
          barrierDismissible: barrierDismissible,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> navigatorPush(MaterialPageRoute route) async {
    if (!mounted) return;
    try {
      final ctx = _rootContext;
      if (ctx == null) return;
      await Navigator.of(ctx).push(route);
    } catch (_) {}
  }

  void appendReasoning(String text) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        answerBuffer.write(text);
        final cb = _onAppendReasoning;
        if (cb != null) cb(text);
        if (workingMessages.isNotEmpty) {
          final last = workingMessages.last;
          last.appendLastThinking(text);
        }
      });
    } catch (_) {}
  }

  ReasoningStep? addReasoningStep(
    String type,
    String label, {
    String? content,
    int? resultCount,
    int? latencyMs,
    String? pluginId,
    String? pluginName,
    String? toolName,
    String status = '',
    String? arguments,
    String? resultSummary,
  }) {
    if (!mounted) return null;
    ReasoningStep? step;
    try {
      _safeSetState(() {
        step = ReasoningStep(
          type,
          content ?? label,
          resultCount: resultCount,
          latencyMs: latencyMs,
          pluginId: pluginId,
          pluginName: pluginName,
          toolName: toolName,
          status: status,
          arguments: arguments,
          resultSummary: resultSummary,
        );
        assistantMsg.addReasoning(step!);
      });
    } catch (_) {}
    return step;
  }

  void updateReasoningStep(
    ReasoningStep? step, {
    String? content,
    int? latencyMs,
    String? status,
    String? resultSummary,
    int? resultCount,
  }) {
    if (!mounted || step == null) return;
    try {
      _safeSetState(() {
        if (content != null) step.content = content;
        if (latencyMs != null) step.latencyMs = latencyMs;
        if (status != null) step.status = status;
        if (resultSummary != null) step.resultSummary = resultSummary;
        if (resultCount != null) step.resultCount = resultCount;
      });
    } catch (_) {}
  }

  void appendUserMessage(String text) {
    if (!mounted) return;
    try {
      final cb = _onAppendUserMessage;
      if (cb != null) cb(text);
    } catch (_) {}
  }

  void finalizeAnswer(String text, {int injectedWebSearchCount = 0, bool forceSave = true}) {
    if (!mounted) return;
    try {
      answered = true;
      answerBuffer.clear();
      answerBuffer.write(text);
      final cb = _onFinalizeAnswer;
      if (cb != null) cb(text, injectedWebSearchCount: injectedWebSearchCount, forceSave: forceSave);
    } catch (_) {}
  }

  void requestStopLoop() {
    if (!mounted) return;
    try {
      final cb = _onRequestStop;
      if (cb != null) cb();
    } catch (_) {}
  }

  void appendAnswerChunk(String chunk) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        answerBuffer.write(chunk);
        if (workingMessages.isNotEmpty) {
          workingMessages.last.content = answerBuffer.toString();
        }
      });
    } catch (_) {}
  }

  void mutateMessageAt(int index, void Function(ChatMessage msg) mutator) {
    if (!mounted) return;
    try {
      if (index < 0 || index >= workingMessages.length) return;
      _safeSetState(() {
        mutator(workingMessages[index]);
      });
    } catch (_) {}
  }

  ChatMessage? lastMessage() {
    try {
      return workingMessages.isEmpty ? null : workingMessages.last;
    } catch (_) {
      return null;
    }
  }

  void addMessage(ChatMessage msg) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        workingMessages.add(msg);
      });
    } catch (_) {}
  }

  void setMounted(bool value) {
    try {
      mounted = value;
    } catch (_) {}
  }

  void setAnswered(bool value) {
    if (!mounted) return;
    try {
      answered = value;
      _onAnsweredChanged?.call(value);
    } catch (_) {}
  }

  void incrementTotalSearchHits([int delta = 1]) {
    try {
      totalSearchHits += delta;
    } catch (_) {}
  }

  void markLastSearchResult(int count, {Duration? latency, String? summary}) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        assistantMsg.markLastSearchResult(
          count: count,
          latencyMs: latency?.inMilliseconds,
          summary: summary ?? '',
        );
      });
    } catch (_) {}
  }

  void setInjectedWebSearchCount(int count) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        assistantMsg.injectedWebSearchCount = count;
      });
    } catch (_) {}
  }

  void setShowStaleFootnote(bool v) {
    if (!mounted) return;
    try {
      _safeSetState(() {
        assistantMsg.showStaleFootnote = v;
      });
    } catch (_) {}
  }

  Future<String?> showAskUser(String question, List<String> options) async {
    final cb = _onShowAskUser;
    if (cb == null) return null;
    if (!mounted) return null;
    try {
      return await cb(question, options);
    } catch (_) {
      return null;
    }
  }

  Future<void> presentAppDownloadSources({
    required String userText,
    required String keyword,
    required List<String> altKeywords,
    required List<String> officialDomains,
    ChatMessage? existingUserMsg,
    ChatMessage? existingPlaceholder,
    String platform = 'android',
  }) async {
    final cb = _onPresentAppDownloadSources;
    if (cb == null || !mounted) return;
    try {
      await cb(
        userText: userText,
        keyword: keyword,
        altKeywords: altKeywords,
        officialDomains: officialDomains,
        existingUserMsg: existingUserMsg,
        existingPlaceholder: existingPlaceholder,
        platform: platform,
      );
    } catch (_) {}
  }

  Future<void> presentFileSources({
    required String userText,
    required String query,
    String? fileType,
    ChatMessage? existingUserMsg,
    ChatMessage? existingPlaceholder,
  }) async {
    final cb = _onPresentFileSources;
    if (cb == null || !mounted) return;
    try {
      await cb(
        userText: userText,
        query: query,
        fileType: fileType,
        existingUserMsg: existingUserMsg,
        existingPlaceholder: existingPlaceholder,
      );
    } catch (_) {}
  }

  Future<void> genericDownload(String url, ChatMessage amsg) async {
    final cb = _onGenericDownload;
    if (cb == null || !mounted) return;
    await cb(url, amsg);
  }

  Future<void> saveAssistantContent({bool force = false}) async {
    final cb = _onSaveAssistantContent;
    if (cb == null) return;
    try {
      await cb(force ? 999999999 : totalSearchHits);
    } catch (_) {}
  }

  void _safeSetState(VoidCallback fn) {
    try {
      fn();
      final setStateCb = _onSetState;
      if (setStateCb != null) setStateCb(() {});
    } catch (_) {}
  }
}
