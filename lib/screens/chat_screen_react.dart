// part 文件通过 extension 访问宿主 _ChatScreenState 的受保护成员 setState，
// 属 part-of + extension 拆分架构的固有模式，统一豁免。
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'chat_screen.dart';


extension ChatScreenReActExt on _ChatScreenState {
  /// v1.7.34：跨对话记忆——每次保存 assistant 消息后触发（不 await，静默后台）
  void _triggerMemorySummaryIfDue() {
    unawaited(ConversationSummaryService.instance
        .maybeRegenerate(conversationId: widget.conversation.id));
  }

  Future<void> _runReActLoop(
    ChatMessage userMsg,
    ApiService apiSvc,
    StorageService storage,
  ) async {
    // v1.7.24：行为指纹兜底 —— 连续 3 轮 thinking 内容指纹相同 → 立即注入自检（不等 20 秒定时器）
    // 场景：AI 原地复读（每轮输出一模一样的 thinking）时空转，20 秒定时器还没触发；指纹检测提前打断。
    String? loopLastThinkingFp;
    int loopRepeatThinkingCount = 0;
    // v1.7.26：流式 answer 过滤跨 chunk 状态（[0]=是否处于 <answer> 块内）
    final ansState = <bool>[false];
    // v1.7.29：跨 chunk 未闭合标签缓冲（流式把 <thinking> 切成 <thin|king> 时暂存，下 chunk 拼接后再剥）
    final pendingTag = <String>[''];

    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    // v1.7.25：思考程度/强度改为每对话独有 → 从 conversation 读取
    final isAuto = widget.conversation.reactAutoMode;
    // v1.7.36：深度研究（会话开关 或 全局插件任一开启）保持其更高轮数上限，不被思考强度覆盖
    final registry = context.read<PluginRegistry>();
    final deepResearchOn = widget.conversation.deepResearchMode ||
        registry.isEnabled(PluginRegistry.kDeepResearchPluginId);
    // 思考强度 > 0 时按 (2 + v*10) 覆盖 ReAct 最大轮数（0.1→3 轮 … 1.0→12 轮）
    var maxRounds = widget.conversation.reactMaxRounds;
    if (!deepResearchOn) {
      final effortRounds = ApiService.reasoningRoundsForValue(
          widget.conversation.reasoningEffort);
      if (effortRounds > 0) maxRounds = effortRounds;
    }
    final effort = ApiService.reasoningEffortForConversation(
        widget.conversation,
        inReAct: true);

    // v1.7.9 (M7 修复)：循环内多轮 await 之后不能再 context.read（页面退出后
    // 会抛 "deactivated widget's ancestor" 崩溃）—— 方法入口一次性缓存服务引用
    final dlSvc = context.read<AppDownloadService>();

    // v1.6.9：PluginRegistry 决定哪些插件能 dispatch，哪些插件的协议能进 prompt。
    //   - 禁用的插件 → registry.dispatch 跳过（不触发功能）
    //   - 禁用的插件 → promptProtocol 也不拼给 AI（AI 根本看不到协议，自然不会输出对应标签）
    final enabledPlugins = registry.plugins
        .where((p) => registry.isEnabled(p.metadata.id))
        .toList(growable: false);
    final hasDownloadPlugin =
        enabledPlugins.any((p) => p.triggerType == 'download');

    // v1.7.31：缓存思考过程日志开关（避免每轮都读 SharedPreferences）
    final logThinking =
        (await SharedPreferences.getInstance()).getBool('log_thinking_process') ?? false;

    _logger.info(
      '[ReAct] Entering loop, STREAMING mode, auto=$isAuto, maxRounds=$maxRounds, effort=$effort, enabledPlugins=${enabledPlugins.map((p) => p.triggerType).join(',')}',
      cat: LogCat.react,
      tag: 'ReAct',
    );

    // v1.6.9：按用户要求"分成两半"——启动的插件拼 promptProtocol（启动版），
    // 禁用的插件完全不拼（不启动版）。市场安装的新插件 register 时顺序在 system 之后，自然追加。
    // v1.7.17：传 hint 走目录层+格式层（详情按需加载）。
    final hint = _pluginHintConfig;
    final reactProtocolPrompt =
        buildReactSystemPromptFromPlugins(enabledPlugins, hint: hint);
    // v1.7.17：🔌 用户附加提示由 _pluginHintConfig.extraHints 驱动。
    final pluginHintBlock = hint.extraHints.isNotEmpty
        ? '\n\n=== 用户附加提示 ===\n${hint.extraHints.join('\n')}'
        : '';
    // 构造一个"临时 system 消息"：给 AI 注入 ReAct 协议（不落库，只在本循环内存中用）
    // v1.7.34：跨对话记忆——如果开启，拼最近几条对话摘要进 system prompt
    String memoryBlock = '';
    if (widget.conversation.memoryEnabled) {
      try {
        final summaries = await storage.getRecentSummaries(3,
            excludeId: widget.conversation.id);
        if (summaries.isNotEmpty) {
          final sb = StringBuffer();
          sb.writeln(isZh
              ? '【跨对话记忆 · 最近对话摘要】'
              : '[Cross-chat memory · Recent conversation summaries]');
          for (final s in summaries) {
            final title = (s['title'] as String?) ?? '';
            final sum = (s['summary'] as String?) ?? '';
            sb.writeln('- $title: $sum');
          }
          memoryBlock = sb.toString().trim();
        }
      } catch (_) {
        // 静默失败，不影响主流程
      }
    }
    final reactSystemMsg = ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.system,
      content: '$reactProtocolPrompt$pluginHintBlock'
          '${memoryBlock.isNotEmpty ? '\n\n$memoryBlock' : ''}',
    );

    // 用于发给 API 的消息列表（系统 prompt + 历史 + user + 每轮 toolresult）
    // 注意：assistant 的 <thinking>/<search> 直接当 assistant 消息发回去（原始完整文本）
    // v1.7.17：重置本循环的 detail 去重集合（同一循环内跨轮去重）。
    _injectedDetails.clear();
    final workingMessages = <ChatMessage>[];
    for (final m in _limitedContext(_messages).where(
        (m) => m.role != MessageRole.assistant || m.content.isNotEmpty)) {
      workingMessages.add(m);
    }

    // v1.4.2：自动压缩 —— 基于 token 估算触发（比消息数量更合理）
    // 阈值：当 workingMessages 估算 token > 4000 时触发压缩
    // 保留最近 6 条消息 + 一条 AI 生成的结构化摘要
    // v1.7.25 修复矛盾：contextAuto（自动上下文·全量保留）与 autoCompress（压缩丢旧消息）
    // 目标相反 → 自动上下文开启时不压缩（保留全量细节）；仅手动上限模式下才压缩。
    if (widget.conversation.autoCompress && !widget.conversation.contextAuto) {
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
          final summary = await _summarizeMessages(apiSvc, oldPart);
          if (!mounted) return;
          if (summary.isNotEmpty) {
            workingMessages
              ..clear()
              ..add(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content:
                    '【上下文压缩摘要 · ${oldPart.length} 条 · ~$estimatedTokens tokens】\n$summary',
              ))
              ..addAll(recentPart);
            _logger.info(
                '[Chat] Auto-compressed: ${oldPart.length} msgs / ~$estimatedTokens tokens → 1 summary',
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
      modelName: (_currentSessionModel ?? _apiConfig)?.model,
      showStaleFootnote: false,
      injectedWebSearchCount: 0,
    )
      ..retryOf = userMsg.retryOf
      ..retryIndex = userMsg.retryIndex
      ..addReasoning(ReasoningStep(
        'thinking',
        isAuto
            ? (isZh
                ? '正在思考是否需要联网搜索…（自动档：AI 自决轮次，上限 $maxRounds 轮）'
                : 'Thinking whether to search the web... (Auto: AI decides, up to $maxRounds rounds)')
            : (isZh
                ? '正在思考是否需要联网搜索…'
                : 'Thinking whether to search the web...'),
        phase: 'phase1_think',
        round: 1,
      ));

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
    var latestRawResp = '';
    Timer? checkTimer;
    if (_enable20sCheck) {
      checkTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (!mounted || !_isStreaming || latestRawResp.isEmpty) return;
        _injectSelfCheck(workingMessages, latestRawResp);
      });
    }

    final apiCfg = _apiConfig!;
    bool answered = false;
    var mcpCalls = 0;
    // v1.7.34：深度研究模式 MCP 上限 8 → 32（配合更多轮数做深度探索）
    // v1.7.36：会话开关 或 深度研究插件（全局）任一开启即生效（deepResearchOn 已在循环入口计算）
    final maxMcpCallsPerMessage = deepResearchOn ? 32 : 8;
    // v1.7.26 (D1)：ReAct 多轮请求级 usage 累加（替换废弃的共享计数器）
    var reactPromptTokens = 0;
    var reactCompletionTokens = 0;
    var reactTotalTokens = 0;

    try {
      // v1.7.26 (E2)：循环边界应为 maxRounds（此前 +1 导致实际多执行一轮）
      for (int round = 0; round < maxRounds; round++) {
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
                ? '🧠 思考中…（轮次 ${round + 1}/$maxRounds，自动档 $effort）'
                : '🧠 思考中…（轮次 ${round + 1}/$maxRounds，程度 $effort）')
            : (isAuto
                ? '🧠 Thinking... (round ${round + 1}/$maxRounds, auto $effort)'
                : '🧠 Thinking... (round ${round + 1}/$maxRounds, effort $effort)');
        _logger.info(
            '[ReAct] Round ${round + 1} start, effort=$effort, auto=$isAuto',
            cat: LogCat.react,
            tag: 'ReAct');
        assistantMsg.startNewThinking('\n$thinkingProgressMsg\n');
        assistantMsg.setLastReasoningPhase('phase${round + 1}_think', round + 1);
        ansState[0] = false; // v1.7.26：每轮重置 answer 流式状态
        pendingTag[0] = ''; // v1.7.29：每轮重置未闭合标签缓冲
        if (mounted) setState(() {});

        // v1.5.5：用 streamChat 替代 completeChat，流式收集 rawResp 的同时实时显示思考内容
        final rawBuf = StringBuffer();
        await for (final chunk in apiSvc.streamChat(
          config: _conversationApiConfig,
          messages: reqList,
          reasoningEffort: effort,
          yieldReasoning: true,
          // v1.7.26 (D1/D5)：scope 级停止 + 每轮 usage 累加（替换废弃的共享计数器）
          stopScope: widget.conversation.id,
          onUsage: (p, c, t) {
            reactPromptTokens += p;
            reactCompletionTokens += c;
            reactTotalTokens += t;
          },
        )) {
          if (_reactLoopStopRequested) break;
          rawBuf.write(chunk);
          // 实时显示：去掉 ReAct 协议标签，只把纯文本追加到 thinking step
          final display = _stripReActTagsForStream(chunk, ansState, pendingTag);
          if (display.isNotEmpty) {
            assistantMsg.appendLastThinking(display);
            if (mounted) setState(() {});
          }
        }
        final rawResp = rawBuf.toString();
        latestRawResp = rawResp;

        _logger.verbose(
            '[ReAct] Round ${round + 1} raw response (${rawResp.length} chars): ${rawResp.substring(0, rawResp.length > 500 ? 500 : rawResp.length)}${rawResp.length > 500 ? '...' : ''}',
            cat: LogCat.react,
            tag: 'ReAct');

        // ---- v1.7.24 行为指纹兜底：连续 3 轮 thinking 内容相同 → 提前注入自检 ----
        final fpText = _extractThinkingFingerprint(rawResp);
        // v1.7.31：用户开启"记录思考过程"时，将完整 thinking 写入日志
        if (logThinking && fpText.isNotEmpty) {
          _logger.verbose(
              '[ReAct] Round ${round + 1} thinking (${fpText.length} chars):\n$fpText',
              cat: LogCat.react,
              tag: 'ReAct-thinking');
        }
        if (fpText.isNotEmpty) {
          if (loopLastThinkingFp != null && fpText == loopLastThinkingFp) {
            loopRepeatThinkingCount++;
          } else {
            loopRepeatThinkingCount = 1;
          }
          loopLastThinkingFp = fpText;
          if (loopRepeatThinkingCount >= 3) {
            _logger.warn(
                '[ReAct] Behavior fingerprint: $loopRepeatThinkingCount consecutive identical thinking rounds — injecting self-check early (not waiting 20s)',
                cat: LogCat.react,
                tag: 'ReAct');
            _injectSelfCheck(workingMessages, rawResp);
            // 注入后重置，避免每轮重复注入；AI 读到自检消息后会改变输出
            loopRepeatThinkingCount = 0;
            loopLastThinkingFp = null;
          }
        }

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
          // ---- v1.7.17：detail 标签（只读加载协议，无副作用）不经过 dispatch ----
          // 直接调契约层纯函数拿详情文本，复用 toolresult 通道注入，_injectedDetails 去重。
          if (type == 'plugin_detail' || type == 'mcp_detail' || type == 'skill_detail') {
            final String detailText;
            final String dedupKey;
            if (type == 'plugin_detail') {
              final name = p['name'] ?? '';
              detailText = resolvePluginDetail(name, enabledPlugins);
              dedupKey = 'plugin:$name';
            } else if (type == 'mcp_detail') {
              final pluginId = p['pluginId'] ?? '';
              final tool = p['tool'] ?? '';
              detailText = resolveMcpDetail(pluginId, tool, enabledPlugins);
              dedupKey = 'mcp:$pluginId.$tool';
            } else {
              final name = p['name'] ?? '';
              detailText = resolveSkillDetail(name, enabledPlugins);
              dedupKey = 'skill:$name';
            }
            if (detailText.isNotEmpty && _injectedDetails.add(dedupKey)) {
              pc.addMessage(ChatMessage.create(
                conversationId: widget.conversation.id,
                role: MessageRole.user,
                content: '<toolresult kind="$type">$detailText</toolresult>',
              ));
              _logger.info(
                  '[ReAct] Injected detail $dedupKey (${detailText.length} chars)',
                  cat: LogCat.react,
                  tag: 'ReAct');
            } else if (detailText.isEmpty) {
              _logger.warn('[ReAct] Detail not found: $dedupKey',
                  cat: LogCat.react, tag: 'ReAct');
            }
            continue;
          }
          // ---- 核心：一行 dispatch，替换 317 行 if/else ----
          final attrs = Map<String, dynamic>.from(p);
          attrs['raw'] = rawResp;
          if (!mounted) return;
          await registry.dispatch(context, pc, type, attrs);
          if (type == 'search' || type == 'search_result') {
            assistantMsg.setLastReasoningPhase(
              'phase${round + 1}_$type', round + 1);
          }
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
      // v1.7.26 (D1)：由各轮 streamChat 的 onUsage 回调累加（上面调用处），不再读已废弃的共享计数器
      assistantMsg.promptTokens =
          reactPromptTokens > 0 ? reactPromptTokens : null;
      assistantMsg.completionTokens = reactCompletionTokens > 0
          ? reactCompletionTokens
          : null;
      assistantMsg.totalTokens =
          reactTotalTokens > 0 ? reactTotalTokens : null;
      await storage.saveMessage(assistantMsg);
      // v1.7.34：跨对话记忆——assistant 消息落库后触发摘要生成
      _triggerMemorySummaryIfDue();
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
    final focusNode = FocusNode();
    // v1.7.31：占位选项集合 —— 点这些不该直接发送，而应聚焦输入框让用户自己写
    const placeholderOpts = {
      '其他', '其它', '自定义', '手动输入', '自己输入', '其他选项', '其他格式',
      '其他类型', '都不是', '以上都不是', '无', '没有', '不确定', '不清楚',
      'other', 'custom', 'none', 'n/a', 'other (please specify)',
    };
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
                      // v1.7.31：占位选项 → 聚焦输入框而非直接发送
                      final isPlaceholder = placeholderOpts.contains(opt.toLowerCase().trim());
                      return ActionChip(
                        label: Text(opt),
                        onPressed: () {
                          if (isPlaceholder) {
                            focusNode.requestFocus();
                          } else {
                            Navigator.pop(ctx, opt);
                          }
                        },
                      );
                    }).toList(),
                  ),
                if (options.isNotEmpty) const SizedBox(height: 8),
                Text(isZh ? '或自己输入：' : 'Or type your own:',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                TextField(
                  controller: textCtrl,
                  focusNode: focusNode,
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
    ).then((result) {
      textCtrl.dispose();
      focusNode.dispose();
      return result;
    });
  }

  // ==========================================================================
  // v1.3.3 build 13 新增：20 秒确认对话框（防卡壳）
  // 用户可选"继续思考"或"终止并输出当前结果"
  // ==========================================================================
  /// v1.3.4：向 workingMessages 注入"系统自检"消息（替代之前的弹窗方案）
  /// AI 下一轮看到这条消息后会输出 <self_check continue="true|false" reason="..."/>
  /// 不弹窗、不打断用户，纯 AI 自检。continue=false 时主循环终止。
  void _injectSelfCheck(
      List<ChatMessage> workingMessages, String rawContent) {
    // v1.7.4 fix: 解析真实的 ReAct 标签内容，而非 reasoningSteps 中的 UI 进度文字
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

  /// v1.7.24：提取原始响应中的 thinking 纯文本（用于行为指纹，判断 AI 是否原地复读）
  /// 只取真实 <thinking> 内容，不含 UI 进度文字（后者混在 reasoningSteps 里，不适合做指纹）。
  String _extractThinkingFingerprint(String rawResp) {
    final buf = StringBuffer();
    for (final m
        in RegExp(r'<thinking>([\s\S]*?)</thinking>').allMatches(rawResp)) {
      buf.write(m.group(1));
    }
    return buf.toString().trim();
  }

  /// v1.5.5：流式显示时去掉 ReAct 协议标签，只保留纯文本（避免用户看到 <search>/<thinking> 等）
  /// v1.7.26 修复（v2，状态化）：<answer> 标签可能跨多个流式 chunk（如 `<answer>内` 一个 chunk、
  /// `容</answer>` 下一个 chunk），纯正则逐 chunk 替换匹配不到未闭合的 answer 块，
  /// 导致最终答案提前混入 thinking step（"思考没结束就出结果、思考完又刷新"）。
  /// 现在用外部状态容器 ansState[0] 跨 chunk 追踪：处于 answer 块内时内容一律丢弃。
  String _stripReActTagsForStream(
      String s, List<bool> ansState, List<String> pendingTag) {
    // v1.7.29：拼接上一 chunk 残留的未闭合标签片段（如 <thin | king> → <thinking>）
    var working = pendingTag[0].isNotEmpty ? pendingTag[0] + s : s;
    pendingTag[0] = '';

    // 末尾若有未闭合的 '<'（其后无 '>'）：暂存到下一 chunk，本 chunk 截断到 '<' 前。
    // 只暂存"像标签开头"的片段（< 后跟字母或 /），避免误吞文本里的比较运算符 <
    final lastLt = working.lastIndexOf('<');
    if (lastLt >= 0) {
      final tail = working.substring(lastLt);
      if (!tail.contains('>') && RegExp(r'^<[a-zA-Z/]').hasMatch(tail)) {
        pendingTag[0] = tail;
        working = working.substring(0, lastLt);
      }
    }

    // 上一 chunk 已进入 answer 块：丢弃直到 </answer> 之后的内容
    if (ansState[0]) {
      final closeIdx = working.indexOf('</answer>');
      if (closeIdx < 0) return '';
      ansState[0] = false;
      working = working.substring(closeIdx + '</answer>'.length);
    }
    // 本 chunk 出现 <answer（可能未闭合）：其之前可显示，之后丢弃并进入 answer 状态
    final ansStart = working.toLowerCase().indexOf('<answer');
    if (ansStart >= 0) {
      final closeIdx = working.indexOf('</answer>', ansStart);
      if (closeIdx >= 0) {
        working = working.substring(0, ansStart) +
            working.substring(closeIdx + '</answer>'.length);
      } else {
        working = working.substring(0, ansStart);
        ansState[0] = true;
      }
    }
    // 其余标签剥离（自闭合 <search/> / mcp_call / 配对 <thinking> 等）
    return working
        .replaceAll(
          RegExp(r'<mcp_call\b[^>]*>[\s\S]*?</mcp_call\s*>',
              caseSensitive: false),
          '',
        )
        .replaceAll(
            RegExp(r'<(plugin_detail|mcp_detail|skill_detail)\b[^>]*?/>',
                caseSensitive: false),
            '') // v1.7.17：detail 只读标签（自闭合）
        .replaceAll(RegExp(r'<[^>]+/>'), '') // 自闭合 <search .../> / <download .../>
        .replaceAll(RegExp(r'</?[^>]+>'), '') // 配对 <thinking> </thinking> 等
        .trim();
  }

  // v1.3.7 Bug #7：方法名从 _extractLastAnswer 改为 _extractFirstAnswer
  // 因为实现用 firstMatch（取第一个）。AI 协议规定只输出一次 <answer>，
  // firstMatch 与 lastMatch 行为等价，方法名与实现保持一致即可。
  String _extractFirstAnswer(String s) {
    final m = RegExp(r'<answer>([\s\S]*?)</answer>', caseSensitive: false)
        .firstMatch(s);
    if (m != null) return m.group(1)!.trim();
    // 没 <answer>：剥离协议思考标签，避免思考内容落入最终答案
    final t = s
        .replaceAll(RegExp(r'<(?:thinking|think)>[\s\S]*?</(?:thinking|think)>',
            caseSensitive: false), '')
        .replaceAll(
            RegExp(r'<(?:thinking|think)>[\s\S]*$', caseSensitive: false), '')
        .trim();
    if (t.isNotEmpty) return t;
    return RegExp(r'<(?:thinking|think)>', caseSensitive: false).hasMatch(s)
        ? ''
        : s;
  }
}
