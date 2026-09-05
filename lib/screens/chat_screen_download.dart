// part 文件通过 extension 访问宿主 _ChatScreenState 的受保护成员 setState，
// 属 part-of + extension 拆分架构的固有模式，统一豁免。
// ignore_for_file: invalid_use_of_protected_member, library_private_types_in_public_api
part of 'chat_screen.dart';

extension ChatScreenDownloadExt on _ChatScreenState {
  // ==========================================================================
  // v1.6.9：ReAct 下载来源呈现（AI 触发的主流程）
  //   本方法负责：
  //     1. 用户消息入聊
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
    final searchStartedAt = DateTime.now();
    var searchTimedOut = false;
    // v1.3.4：GitHub 代理加速（用户在设置里填的，留空=直连）
    final ghProxyUrl = _webSearchCfg.githubProxyUrl;
    // v1.7.25 修复下载：catalog 已命中官方直链 → 不再联网/GitHub 补搜。
    // 之前微信这种有官方源的，还会去 GitHub 搜到无关应用(SmsForwarder)、
    // 去 apkpure 卡 15s 超时，污染来源列表且极慢。官方 catalog 是人工维护
    // 的可信直链，直接展示即可。
    if (!inCatalog && webEnabled) {
      for (int i = 0; i < suffixedWebQuery.length; i++) {
        if (_reactLoopStopRequested || !mounted) break;
        if (DateTime.now().difference(searchStartedAt) >= const Duration(minutes: 2)) {
          searchTimedOut = true;
          break;
        }
        assistantMsg.content = isZh
            ? '🔎 正在汇总下载来源…（${i + 1}/${suffixedWebQuery.length}）'
            : '🔎 Collecting download sources… (${i + 1}/${suffixedWebQuery.length})';
        if (mounted) setState(() {});
        final q = suffixedWebQuery[i];
        // v1.7.26 下载提速：GitHub 与联网搜索对同一查询【并行】执行
        // （此前串行，GitHub 查 repo/release + Online 逐个验证 URL 都耗时）。
        final remaining = const Duration(minutes: 2) -
            DateTime.now().difference(searchStartedAt);
        if (remaining <= Duration.zero) {
          searchTimedOut = true;
          break;
        }
        final results = await Future.wait([
          downloadSvc
              .searchGitHub(q,
                  maxRepos: maxGhReposPerKw, proxyUrl: ghProxyUrl)
              .then((v) => v)
              .catchError((Object e) {
                _logger.warn('[Chat] GitHub search(q=$q) failed: $e',
                    cat: LogCat.download, tag: 'DL');
                return <AppDownloadSource>[];
              }),
          downloadSvc.searchOnline(q, _webSearchCfg).catchError((Object e, StackTrace st) {
            _logger.error('[Chat] Online search(q=$q) failed',
                error: e, stack: st, cat: LogCat.download, tag: 'DL');
            return <AppDownloadSource>[];
          }),
        ]).timeout(remaining, onTimeout: () {
          searchTimedOut = true;
          return <List<AppDownloadSource>>[
            <AppDownloadSource>[],
            <AppDownloadSource>[],
          ];
        });
        addAll(results[0]);
        addAll(results[1]);
        if (sources.length >= 12) break;
      }
    }

    // 5) 写入结果 / 弹出面板
    if (!mounted) return;
    if (searchTimedOut) {
      assistantMsg.content += isZh
          ? '\n⏱️ 汇总查询已达到 2 分钟上限，以下为已找到的来源。'
          : '\n⏱️ The 2-minute search limit was reached; showing sources found so far.';
    }
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
                  '• 所有候选链接验证失败。\n\n'
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
      sb.writeln('${i + 1}. **[${s['sourceName']}](${s['downloadUrl']})**  (${s['sourceDomain']})\n'
          '   [${isZh ? '打开下载链接' : 'Open download link'}](${s['downloadUrl']})\n');
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
                        return FileSourceCard(
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
    const downloadPluginId = 'nexus.builtin.download';
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
    const downloadPluginId = 'nexus.builtin.download';
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
    urlCtrl.dispose();
    fileNameCtrl.dispose();
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
    final taskId = 'react_${DateTime.now().millisecondsSinceEpoch}';
    final uri = Uri.parse(url);
    final fileName = uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty
        ? uri.pathSegments.last
        : 'download.file';
    final source = AppDownloadSource(
      sourceName: uri.host.isEmpty ? url : uri.host,
      sourceDomain: uri.host,
      trustLevel: SourceTrustLevel.unknown,
      version: '—',
      size: '—',
      arch: '—',
      downloadUrl: url,
      referer: uri.origin,
      releaseDate: DateTime.now().toIso8601String().substring(0, 10),
    );

    assistantMsg.content = '📥 ${isZh ? '准备下载' : 'Preparing download'}\n\n$fileName';
    if (mounted) setState(() {});
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => DownloadConfirmDialog(
        appName: fileName,
        source: source,
        highlightOutOfCatalog: true,
      ),
    );
    if (confirmed != true || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => DownloadProgressDialog(appName: fileName, source: source),
    );

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
        if (!mounted) return;
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
}

// ==========================================================================
// v1.4.2：文件来源卡片 widget
// ==========================================================================

class FileSourceCard extends StatelessWidget {
  final Map<String, String> source;
  final String typeLabel;
  final VoidCallback onTap;

  const FileSourceCard({
    super.key,
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
