import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/storage_service.dart';
import '../services/web_search_service.dart';
import 'plugin_interface.dart';
import 'plugin_context.dart';
import 'plugin_registry.dart';

final ReActPlugin kFallbackUnknownTagPlugin = FallbackUnknownTagPlugin();

List<ReActPlugin> get builtinReActPlugins => [
      SearchPlugin(),
      DownloadPlugin(),
      AskUserPlugin(),
      SelfCheckPlugin(),
      AnswerPlugin(),
    ];

PluginRegistry createBuiltinPluginRegistry({StorageService? storage}) {
  final r = PluginRegistry(storage: storage);
  r.registerAll(builtinReActPlugins);
  r.setFallback(kFallbackUnknownTagPlugin);
  return r;
}

class SearchPlugin extends ReActPlugin {
  @override
  String get triggerType => 'search';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.search',
        name: '联网搜索',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '通过 ReAct 协议为 AI 提供联网搜索能力，支持 basic / advanced 两档深度。',
        homepage: 'https://nexus.local/plugins/search',
        minAppVersion: '1.6.8',
        tags: ['内置', '搜索', 'ReAct'],
        promptProtocol: '''
【搜索工具】使用说明：
- 当你需要最新资讯、实时数据或超出训练数据截止日期的信息时，调用搜索工具。
- 输出：<search query="搜索关键词" depth="basic|advanced" />
  - query：搜索引擎友好的中文或英文关键词，短语即可，不要自然长句。
  - depth：basic（快速查询，默认）或 advanced（深入调研，耗 token 约 2 倍，命中更全）。
- 示例 1：最新的 Flutter 3.x 特性
  <search query="Flutter 3 new features 2026" depth="basic" />
- 示例 2：深度调研微信小程序最新架构
  <search query="微信小程序 架构 2026 最新" depth="advanced" />
- 搜索结果会以"工具消息"形式返回给你，你再基于结果给出答案。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc, Map<String, dynamic> attrs) async {
    // v1.7.4 fix: react_parser 把 query 存在 content 字段，不是 query 字段
    final q = (attrs['content'] as String? ?? '').trim();
    final rawDepth = attrs['depth'] as String? ?? 'auto';
    if (q.isEmpty) {
      pc.addReasoningStep('search', '搜索关键词为空，已忽略');
      return;
    }
    final isZh = pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    // tavilyDepth 直接用字符串（basic / advanced），其他值让 searchGeneral 走默认
    final depthLabel = switch (rawDepth.toLowerCase()) {
      'advanced' => isZh ? '高级' : 'Adv',
      'basic' => isZh ? '基础' : 'Basic',
      _ => isZh ? '自动' : 'Auto',
    };
    pc.addReasoningStep('search',
        isZh ? '🔍 正在搜索「$q」（深度：$depthLabel）...' : '🔍 Searching for "$q" (depth: $depthLabel)...');
    final stopwatch = Stopwatch()..start();
    final cfg = (rawDepth.toLowerCase() == 'advanced' || rawDepth.toLowerCase() == 'basic')
        ? pc.webSearchCfg.copyWith(tavilySearchDepth: rawDepth.toLowerCase())
        : pc.webSearchCfg;
    // WebSearchService 是静态类，searchGeneral 返回 List<SearchResultItem>
    final results = await WebSearchService.searchGeneral(q, cfg);
    final hits = results.length;
    pc.incrementTotalSearchHits(hits);
    stopwatch.stop();
    final summary = hits == 0
        ? (isZh ? '未找到有效结果' : 'No results')
        : (isZh ? '命中 ${hits} 条' : 'Got ${hits} results');
    pc.markLastSearchResult(hits, latency: stopwatch.elapsed, summary: summary);
    final isVerbose = pc.webSearchCfg.verboseLogging;
    if (isVerbose) {
      pc.logger.verbose('[ReAct-Search] query=$q depth=$rawDepth hits=$hits latency=${stopwatch.elapsedMilliseconds}ms');
      for (int i = 0; i < results.length && i < 3; i++) {
        final r = results[i];
        pc.logger.verbose('  #${i + 1}  ${r.title}  ${r.url}');
      }
    }
    // 用 static WebSearchService.formatAsSearchContext 把搜索结果拼给 AI
    final formatted = hits > 0 ? WebSearchService.formatAsSearchContext(results, cfg, query: q) : '';
    final sb = StringBuffer();
    sb.writeln('---TOOL RESULT START (search)---');
    sb.writeln('query: ${_xmlEscape(q)}');
    sb.writeln('depth: $rawDepth');
    sb.writeln('hits: $hits');
    sb.writeln('latency_ms: ${stopwatch.elapsedMilliseconds}');
    if (formatted.isNotEmpty) sb.writeln(formatted);
    sb.writeln('---TOOL RESULT END (search)---');
    final userMsgContent = sb.toString();
    final rawResp = pc.rawResp ?? '';
    final amsg = pc.assistantMsg;
    // ChatMessage 没有 copyWith，直接修改 assistantMsg 内容并写入 workingMessages
    amsg.content = rawResp;
    final convId = pc.userMsg?.conversationId ?? amsg.conversationId;
    final u = ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: userMsgContent,
    );
    pc.addMessage(u);
  }
}

class DownloadPlugin extends ReActPlugin {
  @override
  String get triggerType => 'download';

  @override
  RegExp? get legacyTrigger => RegExp(r'(帮我|我要|给我)?下载\s*(安装包|apk)?\s*[：:]?\s*(.+?)(安装包|apk)?\s*[。.!！?？]?$', caseSensitive: false);

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.download',
        name: '文件与应用下载',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '支持 APP 搜索下载（catalog/GitHub/联网）、通用文件按类型搜索下载、URL 直链下载三种子模式。',
        homepage: 'https://nexus.local/plugins/download',
        minAppVersion: '1.6.8',
        tags: ['内置', '下载', '文件', 'APP'],
        promptProtocol: '''
【下载工具】使用说明：
- 使用场景：用户请求下载 APP 安装包、图片、视频、文档、PDF、压缩包等任何需要"保存到本地文件"的内容。
- ⚠️ 核心规则：只要识别出下载意图，【必须】输出 <download> 标签触发下载流程。【禁止】用 <answer> 文字回复"请去官网下载"代替——那样用户什么也下载不到。
- 协议格式：<download intent="true|false" canonical="应用通用名" keywords="关键词1,关键词2,关键词3" domains="官域1,官域2" platform="android|pc" url="直链URL" type="app|pdf|mp4|jpg|doc|any" query="文件名关键词" />
- 三种互斥调用方式（每次只走一条）：
  ① URL 直链下载 → 填 url="https://..."，其他字段默认即可。
  ② 通用文件搜索下载 → type != "app" 且 query 非空（例：type="pdf" query="2026 Flutter 开发手册"）。
  ③ APP 搜索下载 → type="app"（或不写 type），intent="true"，canonical=应用名、keywords=多搜索关键词、domains=官域列表、platform=android 默认、pc 电脑版写 pc。
- 示例 1：下载微信 APP 安卓版
  <download intent="true" canonical="微信" keywords="微信,WeChat APK,微信安卓版" domains="weixin.qq.com" platform="android" />
- 示例 2：2026 年 PDF 报告"年度技术白皮书"
  <download intent="true" type="pdf" query="2026 年度技术白皮书 pdf" />
- 示例 3：下载直链 https://example.com/some-app.apk
  <download intent="true" url="https://example.com/some-app.apk" />
- ❌ 错误做法：用 <answer>回复"您可以去官网下载"——用户无法直接下载。
- ✅ 正确做法：输出 <download intent="true" canonical="..." ... /> 标签，系统会自动搜索来源并弹出下载确认面板。
- 非下载意图 → intent="false"，将被忽略不执行任何操作。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc, Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    final dlUrl = (attrs['url'] as String? ?? '').trim();
    final userMsg = pc.userMsg;
    final amsg = pc.assistantMsg;
    final rawResp = pc.rawResp ?? '';

    // v1.6.9 build42：legacyTrigger（用户输入纯文本"下载微信"，禁用 ReAct 老流程或 registry dispatch legacy）
    //   从 attrs['legacyMatch'] RegExpMatch 捕获组解析 keyword，而不是依赖 XML 属性。
    //   DownloadPlugin.legacyTrigger = (帮我|我要|给我)?下载\s*(安装包|apk)?\s*[：:]?\s*(.+?)(安装包|apk)?\s*[。.!！?？]?$
    //   group(3) = 用户要的核心关键词（"微信"）。
    final legacy = attrs['legacyMatch'] as RegExpMatch?;
    String legacyKeyword = '';
    if (legacy != null) {
      final g = legacy.group(3)?.trim() ?? '';
      // 去掉首尾的"安装包/apk/应用"后缀残留
      legacyKeyword = g.replaceAllMapped(RegExp(r'^(安装包|apk|应用)\s*|\s*(安装包|apk|应用)$', caseSensitive: false), (_) => '').trim();
    }

    if (dlUrl.isNotEmpty && dlUrl.startsWith('http')) {
      pc.setAnswered(true);
      pc.logger.info('[DL] ReAct trigger direct URL: $dlUrl');
      pc.addReasoningStep('download',
          isZh ? '📥 确认直链下载：${_ellipse(dlUrl, 80)}' : '📥 Direct download: ${_ellipse(dlUrl, 80)}');
      amsg.content = rawResp;
      await pc.genericDownload(dlUrl, amsg);
      return;
    }

    // v1.7.9 (M15 修复)：优先读 type_attr
    // parser 片段自带 'type': 'download' 键（片段类型），旧写法 `attrs['type'] ?? attrs['type_attr']`
    // 永远先命中 'download' → AI 显式输出的 type="pdf|mp4|..." 永不生效，文件类型过滤全部失效
    final dlType = (attrs['type_attr'] as String? ?? attrs['type'] as String? ?? 'app').toLowerCase().trim();
    final dlQuery = (attrs['query'] as String? ?? '').trim();

    // 'download' 是片段类型而非文件类型 → 视为 app 下载
    final effectiveDlType = dlType == 'download' ? 'app' : dlType;

    if (effectiveDlType != 'app' && dlQuery.isNotEmpty) {
      pc.logger.info('[DL] ReAct trigger file search: type=$effectiveDlType query=$dlQuery');
      pc.addReasoningStep('download',
          isZh ? '📥 确认是「$effectiveDlType 文件」下载请求，搜索「$dlQuery」...' : '📥 Download file type=$effectiveDlType query="$dlQuery"...');
      amsg.content = rawResp;
      final userText = userMsg?.content ?? dlQuery;
      await pc.presentFileSources(
        userText: userText,
        query: dlQuery,
        fileType: effectiveDlType,
        existingUserMsg: userMsg,
        existingPlaceholder: amsg,
      );
      return;
    }

    final intentRaw = (attrs['intent'] as String? ?? '').toLowerCase().trim();
    final canonical = (attrs['canonical'] as String? ?? attrs['content'] as String? ?? '').trim();
    final keywordsRaw = (attrs['keywords'] as String? ?? '').trim();
    final domainsRaw = (attrs['domains'] as String? ?? '').trim();
    final platform = ((attrs['platform'] as String? ?? '').trim().isNotEmpty ? attrs['platform'] as String : 'android').toLowerCase();
    final altKeywords = keywordsRaw
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != canonical)
        .toList(growable: false);
    final officialDomains = domainsRaw
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    var keyword = canonical;
    if (keyword.isEmpty) {
      keyword = altKeywords.isNotEmpty ? altKeywords.first : '';
    }
    // v1.6.9 build42：legacy 兜底：用户直接输入"下载微信"时 legacyMatch 给出 keyword
    if (keyword.isEmpty && legacyKeyword.isNotEmpty) {
      keyword = legacyKeyword;
    }
    // legacy 场景下默认 intent=true（因为 legacyTrigger 匹配到了就代表用户明确有下载意图）
    var intentTrue = intentRaw == 'true' || intentRaw == '1' || intentRaw == 'yes' || intentRaw == '是';
    if (!intentTrue && legacy != null && keyword.isNotEmpty) {
      intentTrue = true;
    }
    if (!intentTrue || keyword.isEmpty) {
      return;
    }
    pc.setAnswered(true);
    final userText = userMsg?.content ?? keyword;
    final isPC = platform == 'pc';
    final thinkLabel = isZh
        ? (isPC
            ? '📥 确认「$keyword」（电脑端）下载请求，正在准备来源...'
            : '📥 确认「$keyword」（手机端）下载请求，正在准备来源...')
        : (isPC
            ? '📥 Confirmed APP download "$keyword" (PC), preparing sources...'
            : '📥 Confirmed APP download "$keyword" (Android), preparing sources...');
    pc.logger.info('[DL] ReAct trigger app search: keyword=$keyword platform=$platform alt=${altKeywords.length} domains=${officialDomains.length}');
    pc.addReasoningStep('download', thinkLabel);
    amsg.content = rawResp;
    await pc.presentAppDownloadSources(
      userText: userText,
      keyword: keyword,
      altKeywords: altKeywords,
      officialDomains: officialDomains,
      existingUserMsg: userMsg,
      existingPlaceholder: amsg,
      platform: platform,
    );
  }
}

class AskUserPlugin extends ReActPlugin {
  @override
  String get triggerType => 'ask_user';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.ask_user',
        name: 'AI 反问用户',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '当 AI 遇到信息不足、多选决策时，用 <ask_user> 标签弹选项面板向用户提问澄清。',
        homepage: 'https://nexus.local/plugins/ask_user',
        minAppVersion: '1.6.8',
        tags: ['内置', '交互', '反问'],
        promptProtocol: '''
【反问工具】使用说明：
- 当信息不足以推进下一步时（如：下载 APP 不知道用户想要手机版还是电脑版），反问用户。
- ⚠️ 核心规则：<ask_user> 标签内【必须】包含"问题 + 2~8 个选项"，问题与选项、选项与选项之间用"两个竖线 ||"分隔。【禁止】只写问题不带选项——那样用户只能手动打字，体验差。
- 协议格式：<ask_user>问题文案||选项1文案||选项2文案||选项3文案...</ask_user>
- 示例 1：
  <ask_user>你想要下载微信的哪个版本？||手机版 Android||电脑版 Windows||电脑版 Mac</ask_user>
- 示例 2：
  <ask_user>请问报告需要什么格式？||PDF 文档||Word 文档||Markdown 源码</ask_user>
- ❌ 错误做法：只写 <ask_user>你想要哪个版本？</ask_user>（没有选项按钮，用户只能打字）。
- ✅ 正确做法：<ask_user>你想要哪个版本？||手机版||电脑版</ask_user>（有选项按钮可一键点选）。
- 工具会把用户的最终选择以"用户消息"形式注入工作上下文，你在下一轮中直接用用户回复继续。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc, Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    final content = (attrs['content'] as String? ?? '').trim();
    if (content.isEmpty) return;
    final parts = content.split('||').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return;
    var questionText = parts.first;
    var options = parts.length > 1 ? parts.sublist(1) : <String>[];
    // v1.7.7 兜底：AI 没用 || 分隔时（只写问题或用别的分隔符），尝试换行/分号/顿号提取选项
    if (options.isEmpty) {
      final fallbackParts = content
          .split(RegExp(r'[\n;；]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (fallbackParts.length >= 2) {
        questionText = fallbackParts.first;
        options = fallbackParts.sublist(1);
        pc.logger.info(
            '[AskUser] fallback separator parsed ${options.length} options',
            tag: 'Plugin');
      }
    }
    final pcContent = '$questionText${options.isNotEmpty ? ' [${options.join(' / ')}]' : ''}';
    pc.addReasoningStep('ask_user', pcContent);
    pc.appendReasoning(isZh ? '❓ AI 想问你：$questionText' : '❓ AI asks: $questionText');
    final rawResp = pc.rawResp ?? '';
    final amsg = pc.assistantMsg;
    amsg.content = rawResp;
    final reply = await pc.showAskUser(questionText, options);
    final finalReply = (reply == null || reply.trim().isEmpty)
        ? (isZh ? '(用户跳过了这个问题)' : '(User skipped this question)')
        : reply;
    pc.appendReasoning(isZh ? '📩 你的回复：$finalReply' : '📩 Your reply: $finalReply');
    final convId = pc.userMsg?.conversationId ?? amsg.conversationId;
    final pcRole = ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: isZh ? '（用户回复 AI 的提问）：$finalReply' : '(Reply to AI\'s question): $finalReply',
    );
    pc.addMessage(pcRole);
  }
}

class SelfCheckPlugin extends ReActPlugin {
  @override
  String get triggerType => 'self_check';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.self_check',
        name: 'AI 自我终止判定',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '系统每 20 秒自动注入一次自检消息；AI 输出 <self_check> 判定是否停止思考，避免死循环卡壳。',
        homepage: 'https://nexus.local/plugins/self_check',
        minAppVersion: '1.6.8',
        tags: ['内置', '自检', '安全'],
        promptProtocol: '''
【自检工具】使用说明：
- 当你在工作区看到"[系统自检]"消息时，必须输出 <self_check> 标签判定下一步。
- 格式：<self_check continue="true|false" reason="简要说明原因" />
  - continue=true：继续思考或搜索。
  - continue=false：信息已经足够或超过最大轮次，停止思考并总结答案。
- 示例 1（继续）：<self_check continue="true" reason="搜索结果还不够明确，需要再补充一次关键词查询" />
- 示例 2（终止）：<self_check continue="false" reason="信息已齐，输出最终答案" />
- 判定为 false 后，建议紧跟 <answer>...</answer> 标签给出最终回复。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc, Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    final cont = (attrs['continue'] as String? ?? 'true').toLowerCase().trim();
    final reason = (attrs['reason'] as String? ?? '').trim();
    final shouldStop = cont != 'true';
    final actionLabel = isZh
        ? (shouldStop ? '⏹️ 应终止思考' : '▶️ 应继续思考')
        : (shouldStop ? '⏹️ STOP thinking' : '▶️ CONTINUE thinking');
    final reasonLabel = reason.isNotEmpty ? '（$reason）' : '';
    pc.addReasoningStep('self_check', '$actionLabel$reasonLabel');
    pc.appendReasoning(isZh
        ? (shouldStop ? '⏹️ AI 自检判定：应终止思考。$reasonLabel' : '✅ AI 自检判定：继续思考。$reasonLabel')
        : (shouldStop ? '⏹️ Self-check: STOP thinking. $reasonLabel' : '✅ Self-check: CONTINUE thinking. $reasonLabel'));
    if (shouldStop) {
      pc.logger.info('[Chat] AI self-check said STOP (reason: ${reason.isEmpty ? "none" : reason})');
      pc.requestStopLoop();
    }
  }
}

class AnswerPlugin extends ReActPlugin {
  @override
  String get triggerType => 'answer';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.answer',
        name: '最终答案输出',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '当 AI 认为无需进一步思考/搜索时，输出 <answer> 标签结束 ReAct 循环并将正文作为最终回复给用户。',
        homepage: 'https://nexus.local/plugins/answer',
        minAppVersion: '1.6.8',
        tags: ['内置', '输出', 'ReAct'],
        promptProtocol: '''
【最终答案】使用说明：
- 当你准备好给出用户的最终回复时，使用 <answer>...</answer> 把内容包住。
- 支持完整 Markdown：标题、列表、代码块、引用、表格、加粗、斜体、链接、图片。
- 如果前面做了搜索，可以在答案正文中引用搜索到的链接、来源名称。
- 示例：
  <answer>
  ## Flutter 3.x 在 2026 年的三大特性
  1. ...
  2. ...
  参考链接：[搜索命中的标题](https://example.com/x)
  </answer>
- 输出 <answer> 后循环立即结束，不会再让你思考，所以请确保把需要表达的内容一次写完。
- 语言跟随用户：用户用中文回答中文，用户用英文回答英文，不要中英混杂。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc, Map<String, dynamic> attrs) async {
    final answer = attrs['content'] as String? ?? attrs['answer'] as String? ?? '';
    await pc.saveAssistantContent(force: false);
    pc.finalizeAnswer(answer, injectedWebSearchCount: pc.totalSearchHits, forceSave: true);
  }
}

class FallbackUnknownTagPlugin extends ReActPlugin {
  @override
  String get triggerType => '__fallback_unknown__';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: '__fallback_unknown__',
        name: '未知 ReAct 标签兜底',
        version: '1.6.8',
        author: 'Nexus Team',
        description: '当 AI 输出了无法识别的标签时，静默记录为思考步骤，不再导致循环静默丢弃。',
        minAppVersion: '1.6.8',
        tags: ['内置', '兜底'],
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc, Map<String, dynamic> attrs) async {
    final type = attrs['type'] as String? ?? 'unknown';
    final snippet = (attrs['content'] as String? ?? attrs['raw'] as String? ?? '').replaceAll('\n', ' ').trim();
    final preview = snippet.length <= 40 ? snippet : '${snippet.substring(0, 40)}...';
    final isZh = pc.userMsg?.content.contains(RegExp(r'[\u4e00-\u9fff]')) ?? true;
    final label = isZh
        ? '未知 ReAct 标签类型：<$type>（预览：$preview）。已忽略。'
        : 'Unknown ReAct tag <$type> (preview: $preview). Ignored.';
    pc.addReasoningStep('unknown_tag', label);
    pc.logger.warn('[ReAct] Fallback: unknown triggerType=$type preview=$preview');
  }
}

String _xmlEscape(String s) {
  return const HtmlEscape().convert(s);
}

String _ellipse(String s, int max) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}...';
}
