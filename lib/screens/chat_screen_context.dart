// part 文件通过 extension 访问宿主 _ChatScreenState 的受保护成员 setState，
// 属 part-of + extension 拆分架构的固有模式，统一豁免。
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'chat_screen.dart';


extension ChatScreenContextExt on _ChatScreenState {
  // v1.7.34：子代理模式的中英标签
  String _subagentModeLabel(String mode, bool isZh) {
    switch (mode) {
      case 'auto':
        return isZh ? '自动 Auto' : 'Auto';
      case 'main_only':
        return isZh ? '仅主代理' : 'Main only';
      case 'force_search':
        return isZh ? '强制搜索' : 'Force search';
      case 'force_synthesis':
        return isZh ? '强制合成' : 'Force synthesis';
      case 'force_plugin':
        return isZh ? '强制插件' : 'Force plugin';
      default:
        return mode;
    }
  }

  String _subagentModeHint(String mode, bool isZh) {
    switch (mode) {
      case 'auto':
        return isZh
            ? '主代理自动判断：自己回答 / 派 1~3 个专家协助（上限 4 次 LLM 调用）'
            : 'Main agent auto-decides: self-answer or delegate to 1-3 experts (max 4 LLM calls)';
      case 'main_only':
        return isZh
            ? '仅用主代理（走现有 ReAct 循环，不派专家）'
            : 'Use main agent only (existing ReAct loop, no experts)';
      case 'force_search':
        return isZh
            ? '强制走搜索专家：先联网查再合成（适合"最新/热榜"类问题）'
            : 'Force search expert: web search then synthesize (good for "latest/hot" questions)';
      case 'force_synthesis':
        return isZh
            ? '强制走合成专家：不做搜索，直接从上下文组织结论/证据/分歧'
            : 'Force synthesis expert: no search, organize conclusion/evidence/disagreement from context';
      case 'force_plugin':
        return isZh
            ? '强制走插件专家：优先调用已安装插件（MCP / 内置）'
            : 'Force plugin expert: prefer calling installed plugins (MCP / built-in)';
      default:
        return '';
    }
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

  Future<void> _editConversationTitle() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final controller = TextEditingController(text: widget.conversation.title);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '编辑标题' : 'Edit Title'),
        content: TextField(
          controller: controller,
          maxLength: 50,
          autofocus: true,
          decoration: InputDecoration(
            hintText: isZh ? '输入对话标题' : 'Enter conversation title',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(isZh ? '保存' : 'Save'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && result != widget.conversation.title) {
      widget.conversation.title = result;
      if (!mounted) return;
      await context
          .read<StorageService>()
          .updateConversationTitle(widget.conversation.id, result);
      setState(() {});
    }
  }

  Future<void> _showConversationSettings() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    int contextLimit = widget.conversation.contextLimit;
    double temperature = widget.conversation.temperature;
    double topP = widget.conversation.topP;
    bool enable20sCheck = widget.conversation.enable20sCheck;
    bool contextAuto = widget.conversation.contextAuto;
    bool autoCompress = widget.conversation.autoCompress;
    // v1.7.25：思考相关（每对话独有）
    bool reactEnabled = widget.conversation.reactEnabled;
    bool reactAutoMode = widget.conversation.reactAutoMode;
    int reactMaxRounds = widget.conversation.reactMaxRounds;
    double reasoningEffort = widget.conversation.reasoningEffort;
    // v1.7.34：跨对话记忆 + 深度研究 + 子代理模式
    bool memoryEnabled = widget.conversation.memoryEnabled;
    bool deepResearchMode = widget.conversation.deepResearchMode;
    String subagentMode = widget.conversation.subagentMode;

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
                // v1.7.25：自动上下文开启时禁用（全量保留 vs 压缩丢旧消息矛盾）
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '自动压缩' : 'Auto compress'),
                  subtitle: Text(contextAuto
                      ? (isZh
                          ? '自动上下文已开启（全量发送），压缩不生效'
                          : 'Auto context is on (full history); compress is inactive')
                      : (isZh
                          ? '上下文过长时自动把旧消息压缩成摘要（也可在右上角菜单手动压缩）'
                          : 'Automatically compress old messages into a summary when context is too long')),
                  value: autoCompress,
                  onChanged: contextAuto
                      ? null
                      : (value) =>
                          setDialogState(() => autoCompress = value),
                ),
                // ===== v1.7.25：思考相关（每对话独有，原全局 ReAct 页已删）=====
                const Divider(height: 20),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '自主思考 (ReAct)' : 'Autonomous thinking (ReAct)'),
                  subtitle: Text(isZh
                      ? 'AI 自主多轮思考后给出答复'
                      : 'AI thinks over multiple rounds before answering'),
                  value: reactEnabled,
                  onChanged: (v) => setDialogState(() => reactEnabled = v),
                ),
                if (reactEnabled) ...[
                  Text(
                    isZh ? '思考程度（轮数）：' : 'Thinking rounds:',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final opt in const [
                        (label: '关 Off', rounds: 0, auto: false),
                        (label: '低 Low', rounds: 2, auto: false),
                        (label: '中 Medium', rounds: 5, auto: false),
                        (label: '高 High', rounds: 8, auto: false),
                        (label: '自动 Auto', rounds: 30, auto: true),
                      ])
                        ChoiceChip(
                          showCheckmark: false,
                          label: Text(opt.label,
                              style: const TextStyle(fontSize: 11)),
                          selected: opt.auto
                              ? reactAutoMode
                              : !reactAutoMode &&
                                  opt.rounds == reactMaxRounds,
                          selectedColor: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                          onSelected: (_) => setDialogState(() {
                            if (opt.auto) {
                              reactAutoMode = true;
                              reactMaxRounds = 30;
                            } else {
                              reactAutoMode = false;
                              reactMaxRounds = opt.rounds;
                            }
                          }),
                        ),
                    ],
                  ),
                  if (!reactAutoMode) ...[
                    Text(isZh
                        ? '自定义：$reactMaxRounds 轮'
                        : 'Custom: $reactMaxRounds rounds'),
                    Slider(
                      value: reactMaxRounds.toDouble().clamp(0, 100),
                      min: 0,
                      max: 100,
                      divisions: 100,
                      onChanged: (v) =>
                          setDialogState(() => reactMaxRounds = v.round()),
                    ),
                  ],
                  const SizedBox(height: 8),
                  // 思考强度滑块：0.0–1.0 连续（0.1 步进），0=默认(自动)
                  Text(
                    isZh
                        ? '思考强度：${reasoningEffortLabel(reasoningEffort, true)}'
                        : 'Reasoning effort: ${reasoningEffortLabel(reasoningEffort, false)}',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  Slider(
                    value: reasoningEffort.clamp(0.0, 1.0),
                    min: 0,
                    max: 1,
                    divisions: 10,
                    onChanged: (v) => setDialogState(() {
                      reasoningEffort = double.parse(v.toStringAsFixed(1));
                    }),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(isZh ? '默认 0.0' : 'Default 0.0',
                          style: const TextStyle(fontSize: 11)),
                      Text(isZh ? '中 0.5' : 'Medium 0.5',
                          style: const TextStyle(fontSize: 11)),
                      Text(isZh ? '高 1.0' : 'High 1.0',
                          style: const TextStyle(fontSize: 11)),
                    ],
                  ),
                  const Divider(height: 16),
                ],
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
                // ===== v1.7.34：跨对话记忆 + 深度研究 + 子代理编排 =====
                const Divider(height: 20),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '跨对话记忆' : 'Cross-chat memory'),
                  subtitle: Text(isZh
                      ? '发送前把最近几条历史对话摘要拼进 system prompt，AI 记住你之前聊过什么'
                      : 'Injects recent chat summaries into system prompt so the AI remembers prior conversations'),
                  value: memoryEnabled,
                  onChanged: (value) =>
                      setDialogState(() => memoryEnabled = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '深度研究模式' : 'Deep research'),
                  subtitle: Text(isZh
                      ? '自动多专家混合、更多轮数、关闭 20s 自检、MCP 上限 8→32'
                      : 'Auto multi-expert orchestration, more rounds, no 20s check, MCP cap 8→32'),
                  value: deepResearchMode,
                  onChanged: (value) =>
                      setDialogState(() => deepResearchMode = value),
                ),
                // 子代理模式：auto / main_only / force_search / force_synthesis / force_plugin
                Text(
                  isZh ? '子代理模式：' : 'Sub-agent mode:',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in Conversation.kSubagentModes)
                      ChoiceChip(
                        showCheckmark: false,
                        label: Text(_subagentModeLabel(m, isZh),
                            style: const TextStyle(fontSize: 11)),
                        selected: subagentMode == m,
                        selectedColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.12),
                        onSelected: (_) => setDialogState(() => subagentMode = m),
                      ),
                  ],
                ),
                Text(
                  _subagentModeHint(subagentMode, isZh),
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
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
    widget.conversation.reactEnabled = reactEnabled;
    widget.conversation.reactAutoMode = reactAutoMode;
    widget.conversation.reactMaxRounds = reactMaxRounds;
    widget.conversation.reasoningEffort = reasoningEffort;
    // v1.7.34：跨对话记忆 + 深度研究 + 子代理模式
    widget.conversation.memoryEnabled = memoryEnabled;
    widget.conversation.deepResearchMode = deepResearchMode;
    widget.conversation.subagentMode = subagentMode;
    // 深度研究联动：自动档、80 轮、high 思考强度、关闭 20s 自检
    if (deepResearchMode) {
      widget.conversation.reactEnabled = true;
      widget.conversation.reactAutoMode = true;
      if (widget.conversation.reactMaxRounds < 80) {
        widget.conversation.reactMaxRounds = 80;
      }
      widget.conversation.reasoningEffort = 1.0; // high
      widget.conversation.enable20sCheck = false;
    }
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
  // v1.7.17：🔌 插件提示三态（off/manual/auto）切换 + 长按编辑面板（从主文件迁入）
  // ==========================================================================
  /// v1.7.17：点按 🔌 三态循环 off → manual → auto → off（立即持久化）。
  Future<void> _togglePluginHint() async {
    final next = _pluginHintConfig.mode == PluginHintMode.off
        ? PluginHintMode.manual
        : _pluginHintConfig.mode == PluginHintMode.manual
            ? PluginHintMode.auto
            : PluginHintMode.off;
    final nextConfig = _pluginHintConfig.copyWith(mode: next);
    setState(() => _pluginHintConfig = nextConfig);
    await nextConfig.save();
  }

  /// v1.7.17：长按 🔌 弹「三态选择」面板——Radio 选 off/manual/auto；
  /// manual 下列出已启用（registry.isEnabled）的 MCP(kind==mcpRemote) 与
  /// Skill(kind==declarative 且非 system) 插件，多选勾选写入 selectedIds；
  /// 底部保留 extraHints 自由提示词的增删编辑（兼容旧 plugin_hint_items）。
  Future<void> _editPluginHint() async {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final registry = context.read<PluginRegistry>();
    // 手动勾选候选 = 已启用的 MCP + Skill（排除 system 内置声明式插件，与目录层一致）
    final selectable = registry.plugins
        .where((p) => registry.isEnabled(p.metadata.id))
        .where((p) =>
            p.metadata.kind == PluginKind.mcpRemote ||
            (p.metadata.kind == PluginKind.declarative &&
                p.source != PluginSource.system))
        .toList();
    final enabledIds =
        selectable.map((p) => p.metadata.id).toSet();

    var mode = _pluginHintConfig.mode;
    // 勾选集合与已启用集合取交集：禁用掉的插件不再出现在勾选列表，也不会残留。
    final selected = <String>{
      ..._pluginHintConfig.selectedIds.where(enabledIds.contains),
    };
    final extra = List<String>.from(_pluginHintConfig.extraHints);
    final addCtrl = TextEditingController();

    final save = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              title: Text(isZh ? '🔌 插件提示' : '🔌 Plugin hint'),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: RadioGroup<PluginHintMode>(
                    groupValue: mode,
                    onChanged: (v) => setDialogState(() => mode = v!),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      RadioListTile<PluginHintMode>(
                        value: PluginHintMode.off,
                        title: Text(isZh ? '关闭' : 'Off'),
                        subtitle: Text(
                            isZh ? '不注入 MCP/Skill 目录' : 'No MCP/Skill catalog'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<PluginHintMode>(
                        value: PluginHintMode.manual,
                        title: Text(isZh ? '手动' : 'Manual'),
                        subtitle: Text(isZh
                            ? '只注入下方勾选的 MCP/Skill'
                            : 'Only inject selected MCP/Skill'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      if (mode == PluginHintMode.manual) ...[
                        if (selectable.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              isZh ? '暂无已启用的 MCP/Skill 插件' : 'No enabled MCP/Skill plugins',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(dialogCtx).hintColor),
                            ),
                          ),
                        ...selectable.map((p) => CheckboxListTile(
                              value: selected.contains(p.metadata.id),
                              onChanged: (v) => setDialogState(() {
                                if (v == true) {
                                  selected.add(p.metadata.id);
                                } else {
                                  selected.remove(p.metadata.id);
                                }
                              }),
                              title: Text(p.metadata.name,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(
                                '${p.metadata.kind == PluginKind.mcpRemote ? 'MCP' : 'Skill'} · ${p.metadata.id}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(dialogCtx).hintColor),
                              ),
                              dense: true,
                              controlAffinity:
                                  ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                            )),
                        const Divider(),
                      ],
                      RadioListTile<PluginHintMode>(
                        value: PluginHintMode.auto,
                        title: Text(isZh ? '自动' : 'Auto'),
                        subtitle: Text(isZh
                            ? '注入全部已启用的 MCP/Skill'
                            : 'Inject all enabled MCP/Skill'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isZh ? '附加提示词（自由文本）' : 'Extra hints (free text)',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (int i = 0; i < extra.length; i++)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(extra[i],
                                    style: const TextStyle(fontSize: 13)),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 20),
                                  tooltip: isZh ? '删除' : 'Delete',
                                  onPressed: () => setDialogState(
                                      () => extra.removeAt(i)),
                                ),
                              ),
                            if (extra.isEmpty)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  isZh ? '暂无提示词' : 'No hints',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: Theme.of(dialogCtx).hintColor),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: addCtrl,
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: isZh ? '新增提示词…' : 'Add a hint…',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.add),
                            tooltip: isZh ? '添加' : 'Add',
                            onPressed: () {
                              final t = addCtrl.text.trim();
                              if (t.isEmpty) return;
                              setDialogState(() {
                                extra.add(t);
                                addCtrl.clear();
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx, false),
                  child: Text(isZh ? '取消' : 'Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx, true),
                  child: Text(isZh ? '完成' : 'Done'),
                ),
              ],
            );
          },
        );
      },
    );
    addCtrl.dispose();
    if (save != true || !mounted) return;
    final nextConfig = PluginHintConfig(
      mode: mode,
      selectedIds: selected.where(enabledIds.contains).toList()..sort(),
      extraHints: extra,
    );
    setState(() => _pluginHintConfig = nextConfig);
    await nextConfig.save();
  }
}
