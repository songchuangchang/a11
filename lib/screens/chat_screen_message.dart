// part 文件通过 extension 访问宿主 _ChatScreenState 的受保护成员 setState，
// 属 part-of + extension 拆分架构的固有模式，统一豁免。
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'chat_screen.dart';

/// ===== v1.7.22：重试版本快照（原地切换用） =====
/// v1.7.26 (E3)：RetryVersion 已下沉至 models/chat_message.dart（供 StorageService
/// 持久化到 message_versions 表），此处仅保留引用注释。

extension ChatScreenMessageExt on _ChatScreenState {
  Future<void> _sendMessage({String? retryOf, int retryIndex = 0}) async {
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
    _saveDraft();
    // v1.7.26 (E1)：尽早置为流式状态——后续有多个 await（testConnection/搜索/下载意图判定），
    // 若置太晚，用户可在这段窗口内再次点发送绕过 _isStreaming guard 造成并发流
    _isStreaming = true;
    // v1.3.6：快照待发送附件并清空输入栏的 chip 预览
    final pendingAtts = List<MessageAttachment>.from(_pendingAttachments);
    if (mounted) setState(() => _pendingAttachments.clear());
    // 🌐 开关：常驻（不再每次发送后 reset 为 false）
    final bool wasSearchMode = _searchMode;

    if (_apiConfig == null) {
      // 没 AI API Key：只能走"纯下载捷径（正则+内置目录+联网）"兜底，因为无法调 AI
      final handled = await _tryHandleDownloadIntent(text);
      if (handled) {
        // v1.7.26 (E1)：提前置位后需在此复位
        _isStreaming = false;
        if (mounted) setState(() {});
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(AppLocalizations.of(context).tr('apiConfigNotFound'))),
        );
      }
      _isStreaming = false;
      if (mounted) setState(() {});
      return;
    }

    final l = AppLocalizations.of(context);
    final storage = context.read<StorageService>();
    final apiSvc = context.read<ApiService>();
    final registry = context.read<PluginRegistry>();

    final now = DateTime.now();
    final cacheValid = _lastApiTestTime != null &&
        _lastApiTestOk &&
        now.difference(_lastApiTestTime!) < const Duration(seconds: 30);
    if (!cacheValid) {
      try {
        await apiSvc
            .testConnection(_conversationApiConfig)
            .timeout(const Duration(seconds: 10));
        _lastApiTestOk = true;
        _lastApiTestTime = now;
      } catch (e) {
        _lastApiTestOk = false;
        _lastApiTestTime = now;
        if (mounted) {
          final isZh = l.locale.languageCode == 'zh';
          final errStr = e.toString();
          final shortErr = errStr.length > 200 ? '${errStr.substring(0, 200)}...' : errStr;
          final proceed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(isZh ? '⚠️ API 连接失败' : '⚠️ API Connection Failed'),
              content: Text(isZh
                  ? '无法连接到 API 服务器：\n\n$shortErr\n\n是否仍然发送消息？'
                  : 'Cannot connect to API server:\n\n$shortErr\n\nSend message anyway?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(isZh ? '取消' : 'Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(isZh ? '仍然发送' : 'Send Anyway'),
                ),
              ],
            ),
          );
          if (proceed != true) {
            // v1.7.26 (E1)：提前置位后需在此复位
            _isStreaming = false;
            if (mounted) setState(() {});
            return;
          }
        }
      }
    }

    final userMsg = ChatMessage.create(
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: text,
      modelName: (_currentSessionModel ?? _apiConfig)?.model,
    );
    if (retryOf != null) {
      userMsg.retryOf = retryOf;
      userMsg.retryIndex = retryIndex;
    }
    // v1.3.6：把待发送附件挂到 userMsg（API 调用时由 _buildMessagesPayload 处理多模态）
    if (pendingAtts.isNotEmpty) {
      userMsg.attachments.addAll(pendingAtts);
    }

    // 自动用首条消息设置对话标题
    if (widget.conversation.title == 'New Chat') {
      final newTitle = text.length > 30
          ? '${text.substring(0, 30)}...'
          : text;
      await storage.updateConversationTitle(widget.conversation.id, newTitle);
      widget.conversation.title = newTitle;
    }
    await storage.saveMessage(userMsg);

    // ===== v1.3.2：ReAct 自主思考 + 搜索循环（Chatbox 风格）=====
    // v1.6.9 build42 修复问题4：思考循环与联网搜索解耦——
    //   - 不再依赖 wasSearchMode / webSearchEnabled（关搜索也能思考，只思考不搜索）
    //   - 依赖 self_check 插件启用（失去自检终止保护则 🧠 整体禁用）
    // v1.7.25：思考相关每对话独有 → 读 conversation
    final shouldUseReAct = widget.conversation.reactEnabled &&
        widget.conversation.reactMaxRounds > 0 &&
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
      modelName: (_currentSessionModel ?? _apiConfig)?.model,
      showStaleFootnote: willWarnStaleKnowledge,
      injectedWebSearchCount: searchHitCount,
    );
    if (retryOf != null) {
      assistantMsg.retryOf = retryOf;
      assistantMsg.retryIndex = retryIndex;
    }

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

    // v1.7.17：🔌 非 ReAct 普通聊天按三态注入提示文本（偷偷注入，对话框看不到）。
    //   off 不注入；manual/auto 注入 extraHints；auto 额外注入 enabled MCP/Skill
    //   小目录摘要（仅提示文本，不引入 detail 协议）。
    final hintInjection = _buildNormalChatPluginHint(registry);
    if (hintInjection.isNotEmpty) {
      outgoing = [
        ChatMessage.create(
          conversationId: userMsg.conversationId,
          role: MessageRole.system,
          content: hintInjection,
        ),
        ...outgoing,
      ];
    }

    // v1.7.34：跨对话记忆——非 ReAct 路径也注入最近几条对话摘要
    if (widget.conversation.memoryEnabled) {
      try {
        final summaries = await storage.getRecentSummaries(3,
            excludeId: widget.conversation.id);
        if (summaries.isNotEmpty) {
          final sb = StringBuffer();
          final isZh = l.locale.languageCode == 'zh';
          sb.writeln(isZh
              ? '【跨对话记忆 · 最近对话摘要】'
              : '[Cross-chat memory · Recent conversation summaries]');
          for (final s in summaries) {
            final title = (s['title'] as String?) ?? '';
            final sum = (s['summary'] as String?) ?? '';
            sb.writeln('- $title: $sum');
          }
          outgoing = [
            ChatMessage.create(
              conversationId: userMsg.conversationId,
              role: MessageRole.system,
              content: sb.toString().trim(),
            ),
            ...outgoing,
          ];
        }
      } catch (_) {}
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
        // v1.7.25：思考强度每对话独有（手动选时传，默认不传保持现状）
        reasoningEffort: ApiService.reasoningEffortForConversation(
            widget.conversation,
            inReAct: false),
        // v1.7.26 (D1/D5)：scope 级停止 + 请求级 usage 归账（替换废弃的共享计数器）
        stopScope: widget.conversation.id,
        onUsage: (p, c, t) {
          assistantMsg.promptTokens = p > 0 ? p : null;
          assistantMsg.completionTokens = c > 0 ? c : null;
          assistantMsg.totalTokens = t > 0 ? t : null;
        },
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
      // v1.7.26 (D1)：由 streamChat 的 onUsage 回调捕获（上面调用处），这里不再读已废弃的共享计数器
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
    // v1.7.26 (D5)：scope 级停止——只停当前会话的流（ReAct 循环走 _reactLoopStopRequested 自有开关）
    context.read<ApiService>().stopGeneration(scope: widget.conversation.id);
    // v1.4.2 修复：停止按钮同时终止 ReAct 循环。
    // 之前只 stopGeneration()（只对 streamChat 的 _shouldStop 生效），
    // ReAct 循环走 completeChat（非流式）停不下来，导致按钮"点不动"。
    _reactLoopStopRequested = true;
    _logger.info('[Chat] Generation stopped by user',
        cat: LogCat.chat, tag: 'Chat');
  }

  Future<void> _retryMessage(ChatMessage assistantMsg) async {
    final idx = _messages.indexOf(assistantMsg);
    if (idx <= 0) return;

    ChatMessage? userMsg;
    for (int i = idx - 1; i >= 0; i--) {
      if (_messages[i].role == MessageRole.user) {
        userMsg = _messages[i];
        break;
      }
    }
    if (userMsg == null) return;

    if (_isStreaming) return;

    final retryOfId = userMsg.retryOf.isEmpty ? userMsg.id : userMsg.retryOf;

    // v1.7.26 (E3)：重试版本快照持久化到独立 message_versions 表——v1.7.22
    // 的快照仅存内存，App 重启后版本切换与计数全部丢失
    final versions = _retryVersionStore.putIfAbsent(retryOfId, () => []);
    versions.add(RetryVersion(
      content: assistantMsg.content,
      reasoningSteps: List<ReasoningStep>.from(assistantMsg.reasoningSteps),
      promptTokens: assistantMsg.promptTokens,
      completionTokens: assistantMsg.completionTokens,
      totalTokens: assistantMsg.totalTokens,
      injectedWebSearchCount: assistantMsg.injectedWebSearchCount,
      showStaleFootnote: assistantMsg.showStaleFootnote,
      modelName: assistantMsg.modelName ?? '',
    ));
    _activeRetryVersionIndex[retryOfId] = versions.length;
    final storage = context.read<StorageService>();
    await storage.saveMessageVersion(retryOfId, versions.length, versions.last);

    // v1.7.26 (E4)：原位重插需沿用旧 pair 的 createdAt。DB 按 createdAt ASC
    // 排序加载会话，若沿用新时间，重载后重试 pair 会跑到列表末尾
    final oldUserCreatedAt = userMsg.createdAt;
    final oldAssistantCreatedAt = assistantMsg.createdAt;

    final userMsgId = userMsg.id;
    final assistantMsgId = assistantMsg.id;

    await storage.deleteMessage(assistantMsgId);
    await storage.deleteMessage(userMsgId);

    int maxIndex = 0;
    for (final m in _messages) {
      if (m.retryOf == retryOfId) {
        if (m.retryIndex > maxIndex) maxIndex = m.retryIndex;
      }
    }
    final nextIndex = maxIndex + 1;

    _inputController.text = userMsg.content;
    _pendingAttachments
      ..clear()
      ..addAll(userMsg.attachments);
    if (mounted) {
      setState(() {
        _messages.removeWhere((m) => m.id == userMsgId || m.id == assistantMsgId);
      });
    }

    await _sendMessage(retryOf: retryOfId, retryIndex: nextIndex);

    if (mounted && _messages.isNotEmpty) {
      // 从末尾找新生成的 user/assistant pair（普通路径与 ReAct 路径都会带 retryOf）。
      // 无 AI 配置时 _sendMessage 走下载兜底直接返回、不产生新 pair → 整体跳过。
      ChatMessage? newUser;
      ChatMessage? newAssistant;
      for (int i = _messages.length - 1; i >= 0; i--) {
        final m = _messages[i];
        if (m.role == MessageRole.assistant && m.retryOf == retryOfId) {
          newAssistant ??= m;
        } else if (m.role == MessageRole.user && m.retryOf == retryOfId) {
          newUser ??= m;
        }
        if (newAssistant != null && newUser != null) break;
      }

      if (newAssistant != null) {
        final versions = _retryVersionStore.putIfAbsent(retryOfId, () => []);
        versions.add(RetryVersion(
          content: newAssistant.content,
          reasoningSteps: List<ReasoningStep>.from(newAssistant.reasoningSteps),
          promptTokens: newAssistant.promptTokens,
          completionTokens: newAssistant.completionTokens,
          totalTokens: newAssistant.totalTokens,
          injectedWebSearchCount: newAssistant.injectedWebSearchCount,
          showStaleFootnote: newAssistant.showStaleFootnote,
          modelName: newAssistant.modelName ?? '',
        ));
        _activeRetryVersionIndex[retryOfId] = versions.length;
        await storage.saveMessageVersion(retryOfId, versions.length, versions.last);

        if (newUser != null) {
          // v1.7.26 (E4)：原位重插——把追加到末尾的新 pair 移回旧 pair 原本的
          // 位置（旧 pair 已被移除，插入点即 idx - 1），并回写 createdAt 后重新
          // 落库（saveMessage 为 replace 语义按 id 覆盖），保证 DB 重载顺序不变
          final nu = newUser;
          final na = newAssistant;
          final targetIdx = idx - 1;
          nu.createdAt = oldUserCreatedAt;
          na.createdAt = oldAssistantCreatedAt;
          _messages
            ..removeWhere((m) => m.id == nu.id || m.id == na.id)
            ..insert(targetIdx, nu)
            ..insert(targetIdx, na);
          await storage.saveMessage(nu);
          await storage.saveMessage(na);
        }
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _rollbackMessage(ChatMessage userMsg) async {
    if (_isStreaming) return;
    final idx = _messages.indexOf(userMsg);
    if (idx < 0) return;

    // v1.7.25 修复：撤回支持任意一条用户消息（v1.7.22 误加"仅最后一条"限制，
    // 导致历史消息撤回点了没反应）。语义：撤回该条提问 → 级联删除它及其后的
    // 所有消息（后续回答/追问都依赖这条提问）。
    if (_messages.length < 2) return;
    final toDelete = _messages.sublist(idx).toList();

    final storage = context.read<StorageService>();
    // v1.7.26 (E5)：级联删除走单事务，避免中途失败留下半删状态
    await storage.deleteMessagesByIds(toDelete.map((m) => m.id).toList());

    // v1.7.22：清理重试版本存储
    final retryOfId = userMsg.retryOf.isEmpty ? userMsg.id : userMsg.retryOf;
    // v1.7.26 (E3)：同步清理持久化版本快照，避免孤儿数据残留
    await storage.deleteMessageVersions(retryOfId);
    _retryVersionStore.remove(retryOfId);
    _activeRetryVersionIndex.remove(retryOfId);

    _inputController.text = userMsg.content;
    _pendingAttachments
      ..clear()
      ..addAll(userMsg.attachments);

    if (mounted) {
      setState(() {
        _messages.removeWhere((m) => toDelete.contains(m));
      });
    }
  }

  String _retryOfId(ChatMessage msg) {
    if (msg.retryOf.isNotEmpty) return msg.retryOf;
    if (msg.role != MessageRole.assistant) return '';
    final idx = _messages.indexOf(msg);
    if (idx <= 0) return '';
    for (int i = idx - 1; i >= 0; i--) {
      if (_messages[i].role == MessageRole.user) {
        return _messages[i].retryOf.isEmpty
            ? _messages[i].id
            : _messages[i].retryOf;
      }
    }
    return '';
  }

  int _computeRetryVersionCount(ChatMessage msg) {
    if (msg.role != MessageRole.assistant) return 0;
    final retryOf = _retryOfId(msg);
    if (retryOf.isEmpty) return 0;
    final versions = _retryVersionStore[retryOf];
    return versions?.length ?? 0;
  }

  int _computeRetryVersionIndex(ChatMessage msg) {
    if (msg.role != MessageRole.assistant) return 0;
    final retryOf = _retryOfId(msg);
    if (retryOf.isEmpty) return 0;
    return _activeRetryVersionIndex[retryOf] ?? 0;
  }

  Future<void> _switchRetryVersion(ChatMessage currentMsg, int direction) async {
    final retryOf = _retryOfId(currentMsg);
    if (retryOf.isEmpty) return;

    final versions = _retryVersionStore[retryOf];
    if (versions == null || versions.length <= 1) return;

    final currentIdx = _activeRetryVersionIndex[retryOf] ?? versions.length;
    final newIdx = (currentIdx + direction).clamp(1, versions.length);
    if (newIdx == currentIdx) return;

    _activeRetryVersionIndex[retryOf] = newIdx;
    final target = versions[newIdx - 1];

    currentMsg.content = target.content;
    currentMsg.reasoningSteps
      ..clear()
      ..addAll(target.reasoningSteps);
    currentMsg.promptTokens = target.promptTokens;
    currentMsg.completionTokens = target.completionTokens;
    currentMsg.totalTokens = target.totalTokens;
    currentMsg.injectedWebSearchCount = target.injectedWebSearchCount;
    currentMsg.showStaleFootnote = target.showStaleFootnote;
    currentMsg.modelName = target.modelName.isNotEmpty ? target.modelName : null;

    // v1.7.26 (E3)：切换结果落库——原地切换不新建会话，若不持久化则重启后
    // 展示的 content/reasoningSteps 仍是切换前的版本，切换等于丢失。
    await context.read<StorageService>().saveMessage(currentMsg);

    if (mounted) setState(() {});
  }
}
