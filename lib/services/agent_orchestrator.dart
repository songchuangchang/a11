// v1.7.34：子代理编排器
//
// 流程：
//   主 Agent（route） → 专家（0~3 个，串行）→ 主 Agent（synthesize）
//
// 与 ReAct 循环的分工：
//   - subagentMode == 'main_only' → 完全走现有 ReAct 循环（不动）
//   - subagentMode != 'main_only' → 走本编排器
//
// 上限：一次用户消息最多 4 次 LLM 调用（主 → 专家 → 主合成，最多两轮专家）

import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/web_search_config.dart';
import '../prompts/agent_prompts.dart';
import 'agent_parser.dart';
import 'api_service.dart';
import 'logger_service.dart';
import 'web_search_service.dart';

/// 编排结果
class OrchestrationResult {
  final String answer;
  final List<ReasoningStep> reasoningSteps;
  final int llmCallCount;

  OrchestrationResult({
    required this.answer,
    required this.reasoningSteps,
    required this.llmCallCount,
  });
}

class AgentOrchestrator {
  AgentOrchestrator(this.api, this.logger);

  final ApiService api;
  final LoggerService logger;

  static const int kMaxLlmCalls = 4;

  /// 运行一次编排。若返回 null 表示编排失败（调用方可回退到 ReAct 循环）。
  Future<OrchestrationResult?> run({
    required ChatMessage userMsg,
    required ApiConfig cfg,
    required Conversation conversation,
    required WebSearchConfig webCfg,
    List<Map<String, String>> availablePlugins = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final isZh = conversation.title.isNotEmpty &&
        conversation.title.runes.any((r) =>
            (r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF));
    final deep = conversation.deepResearchMode;
    final forceMode = conversation.subagentMode; // auto / force_search / ...

    final steps = <ReasoningStep>[];
    var callCount = 0;

    // =========================================================================
    // Step 1: 主 Agent —— 路由
    // =========================================================================
    String target;
    String routeReason = '';
    if (forceMode == 'force_search') {
      target = 'search';
      routeReason = 'forced by user';
    } else if (forceMode == 'force_synthesis') {
      target = 'synthesis';
      routeReason = 'forced by user';
    } else if (forceMode == 'force_plugin') {
      target = 'plugin';
      routeReason = 'forced by user';
    } else {
      // auto / main_only（main_only 不会进本编排器）
      final routerPrompt = buildMainAgentPrompt(
        isZh: isZh,
        deepResearch: deep,
        stageSynthesize: false,
      );
      final routeResp = await _call(
        cfg: cfg,
        messages: [
          ChatMessage.create(
              conversationId: conversation.id,
              role: MessageRole.system,
              content: routerPrompt),
          ChatMessage.create(
              conversationId: conversation.id,
              role: MessageRole.user,
              content: userMsg.content),
        ],
        timeout: const Duration(seconds: 30),
      );
      callCount++;
      final parsedRoute = parseRouteTag(routeResp);
      if (parsedRoute.reason == 'no <route> tag') {
        logger.warn(
            '[Orchestrator] no <route> tag found in route response; falling back to self. raw=${routeResp.length > 200 ? '${routeResp.substring(0, 200)}…' : routeResp}',
            tag: 'Orch');
      }
      target = parsedRoute.target;
      routeReason = parsedRoute.reason;
      // 深度研究模式强制不允许 self
      if (deep && target == 'self') {
        target = 'synthesis';
        routeReason += ' [deep-research override]';
      }
      steps.add(ReasoningStep(
        'route',
        'target=$target reason=$routeReason',
        phase: 'route',
        round: 1,
      ));
      logger.info(
          '[Orchestrator] route → target=$target reason=$routeReason (deep=$deep, force=$forceMode)',
          tag: 'Orch');
    }

    // =========================================================================
    // Step 2: 分派专家
    // =========================================================================
    final expertOutputs = <String, String>{};

    if (target == 'self') {
      // 主 Agent 自己答（跳过专家），走合成阶段
    } else if (target == 'search') {
      if (callCount >= kMaxLlmCalls) return null;
      final queries = await _dispatchSearchAgent(
        cfg: cfg,
        conversation: conversation,
        userText: userMsg.content,
        isZh: isZh,
      );
      callCount++;
      steps.add(ReasoningStep(
        'search_queries',
        'queries=${queries.length}: ${queries.join(' | ')}',
        phase: 'expert',
        round: 1,
      ));
      // 执行实际网络搜索
      final searchResults = await _executeSearch(queries, webCfg);
      final joined = _formatSearchResults(searchResults);
      expertOutputs['search'] = joined;
      steps.add(ReasoningStep(
        'search_results',
        'hits=${searchResults.length}, chars=${joined.length}',
        phase: 'expert',
        round: 1,
      ));

      // 深度研究模式：搜索后追加综合
      if (deep && callCount < kMaxLlmCalls) {
        final synText = await _dispatchSynthesisAgent(
          cfg: cfg,
          conversation: conversation,
          userText: userMsg.content,
          evidence: joined,
          isZh: isZh,
        );
        callCount++;
        expertOutputs['synthesis'] = synText;
        steps.add(ReasoningStep(
          'synthesis',
          'chars=${synText.length}',
          phase: 'expert',
          round: 2,
        ));
      }
    } else if (target == 'synthesis') {
      // 无搜索证据也允许综合（AI 用已有知识做结构化分析）
      if (callCount >= kMaxLlmCalls) return null;
      final synText = await _dispatchSynthesisAgent(
        cfg: cfg,
        conversation: conversation,
        userText: userMsg.content,
        evidence: '',
        isZh: isZh,
      );
      callCount++;
      expertOutputs['synthesis'] = synText;
      steps.add(ReasoningStep(
        'synthesis',
        'chars=${synText.length} (no search evidence)',
        phase: 'expert',
        round: 1,
      ));
    } else if (target == 'plugin') {
      if (callCount >= kMaxLlmCalls) return null;
      final pluginText = await _dispatchPluginAgent(
        cfg: cfg,
        conversation: conversation,
        userText: userMsg.content,
        plugins: availablePlugins,
        isZh: isZh,
      );
      callCount++;
      expertOutputs['plugin'] = pluginText;
      steps.add(ReasoningStep(
        'plugin_call',
        pluginText.length > 200 ? '${pluginText.substring(0, 200)}…' : pluginText,
        phase: 'expert',
        round: 1,
      ));
    }

    // =========================================================================
    // Step 3: 主 Agent —— 合成最终回答
    // =========================================================================
    if (callCount >= kMaxLlmCalls) {
      logger.warn(
          '[Orchestrator] LLM call limit reached before synthesis; using expert output as fallback',
          tag: 'Orch');
      final fallback = expertOutputs.values.join('\n\n')
          .isEmpty
          ? '（编排未产出最终回答）'
          : expertOutputs.values.join('\n\n');
      return OrchestrationResult(
        answer: fallback,
        reasoningSteps: steps,
        llmCallCount: callCount,
      );
    }

    final synthPrompt = buildMainAgentPrompt(
      isZh: isZh,
      deepResearch: deep,
      stageSynthesize: true,
    );
    final expertBlock = expertOutputs.entries.map((e) {
      return '=== ${e.key.toUpperCase()} 专家输出 ===\n${e.value}';
    }).join('\n\n');

    final synthResp = await _call(
      cfg: cfg,
      messages: [
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.system,
            content: synthPrompt),
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.user,
            content:
                '用户问题：${userMsg.content}\n\n$expertBlock'),
      ],
      timeout: timeout,
    );
    callCount++;
    steps.add(ReasoningStep(
      'final_answer',
      'chars=${synthResp.length}',
      phase: 'synthesize',
      round: steps.length ~/ 2 + 1,
    ));

    final answer = stripAnswerTag(synthResp);
    return OrchestrationResult(
      answer: answer,
      reasoningSteps: steps,
      llmCallCount: callCount,
    );
  }

  // ===========================================================================
  // LLM 调用薄封装（temperature=0.1，reasoningEffort=low 便于快速决策）
  // ===========================================================================
  Future<String> _call({
    required ApiConfig cfg,
    required List<ChatMessage> messages,
    required Duration timeout,
  }) async {
    return api.completeChat(
      config: cfg,
      messages: messages,
      reasoningEffort: 'low',
      timeout: timeout,
    );
  }

  // ===========================================================================
  // 解析工具
  // ===========================================================================

  // 解析逻辑已抽到 lib/services/agent_parser.dart（纯函数，可单测）

  // ===========================================================================
  // 专家分派（每个专家 = 一次独立 LLM 调用）
  // ===========================================================================
  Future<List<String>> _dispatchSearchAgent({
    required ApiConfig cfg,
    required Conversation conversation,
    required String userText,
    required bool isZh,
  }) async {
    final prompt = buildSearchAgentPrompt(isZh: isZh);
    final resp = await _call(
      cfg: cfg,
      messages: [
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.system,
            content: prompt),
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.user,
            content: userText),
      ],
      timeout: const Duration(seconds: 40),
    );
    final queries = extractQueries(resp);
    // 保底：一条都没有时至少用原文
    if (queries.isEmpty) return [userText];
    return queries;
  }

  Future<String> _dispatchSynthesisAgent({
    required ApiConfig cfg,
    required Conversation conversation,
    required String userText,
    required String evidence,
    required bool isZh,
  }) async {
    final prompt = buildSynthesisAgentPrompt(isZh: isZh);
    final evidenceBlock =
        evidence.isEmpty ? '（无外部证据，仅基于你已有的知识）' : evidence;
    final resp = await _call(
      cfg: cfg,
      messages: [
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.system,
            content: prompt),
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.user,
            content:
                '用户问题：$userText\n\n已收集证据：\n$evidenceBlock'),
      ],
      timeout: const Duration(minutes: 3),
    );
    return extractSynthesis(resp);
  }

  Future<String> _dispatchPluginAgent({
    required ApiConfig cfg,
    required Conversation conversation,
    required String userText,
    required List<Map<String, String>> plugins,
    required bool isZh,
  }) async {
    final prompt =
        buildPluginAgentPrompt(isZh: isZh, availablePlugins: plugins);
    final resp = await _call(
      cfg: cfg,
      messages: [
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.system,
            content: prompt),
        ChatMessage.create(
            conversationId: conversation.id,
            role: MessageRole.user,
            content: userText),
      ],
      timeout: const Duration(seconds: 40),
    );
    return resp.trim();
  }

  // ===========================================================================
  // 实际网络搜索（复用现有 WebSearchService）
  // ===========================================================================
  Future<List<SearchResultItem>> _executeSearch(
      List<String> queries, WebSearchConfig cfg) async {
    if (!cfg.webSearchEnabled || queries.isEmpty) return [];
    final out = <SearchResultItem>[];
    try {
      for (final q in queries.take(3)) {
        final r = await WebSearchService.searchGeneral(q, cfg);
        out.addAll(r);
        if (out.length >= cfg.maxResultsInject) break;
      }
    } catch (e) {
      logger.warn('[Orchestrator] web search failed: $e', tag: 'Orch');
    }
    return out;
  }

  String _formatSearchResults(List<SearchResultItem> items) {
    if (items.isEmpty) return '（无搜索结果）';
    final sb = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      sb.writeln('[${i + 1}] ${it.title}');
      sb.writeln('URL: ${it.url}');
      sb.writeln('摘要: ${it.snippet}');
      sb.writeln();
    }
    return sb.toString().trim();
  }
}
