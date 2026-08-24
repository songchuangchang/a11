import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/web_search_config.dart';
import '../plugins/plugin_interface.dart';
import 'logger_service.dart';

/// v1.6.9：动态根据「启用的插件」生成 ReAct system prompt。
/// 规则（来自用户）：
///   - 启用的插件 → 把插件的 promptProtocol 说明拼接进去（"启动版"）
///   - 禁用的插件 → 完全不拼接（"不启动版"）
///   - 市场安装的新插件 → register 时追加，顺序在 system 之后（"安装完加后面"）
String buildReactSystemPromptFromPlugins(Iterable<ReActPlugin> enabledPlugins,
    {bool includeThinkingGuide = true}) {
  final sb = StringBuffer();
  final ordered = enabledPlugins.toList();
  // v1.6.9 build42 修复问题4：前言/结尾的"搜索引导"文字此前硬编码，未随 search 插件插拔。
  // 现在按插件实际启用状态动态生成：search 禁用 → 不再引导 AI 搜索。
  final hasSearch = ordered.any((p) => p.triggerType == 'search');
  final hasDownload = ordered.any((p) => p.triggerType == 'download');
  sb.writeln();
  if (hasSearch) {
    sb.writeln(
        '你目前运行在「自主联网思考循环 (ReAct)」模式中。你可以像人类查资料那样：先把自己的思考过程写出来、判断是否需要联网补信息、做一次或多次搜索、把信息纳入参考后，再给出最终回答。');
  } else {
    sb.writeln(
        '你目前运行在「自主思考循环 (ReAct)」模式中。联网搜索已被禁用，请直接基于已有知识思考并回答，不要输出 <search> 标签。');
  }
  sb.writeln();
  sb.writeln('=== 输出协议（必须严格遵守）===');
  if (includeThinkingGuide) {
    sb.writeln('1) 你写的每一段内部思考，请用 <thinking>...</thinking> 标签包裹。');
    sb.writeln('   内容可以写：你接下来打算查什么、为什么、现在掌握了哪些关键点、缺什么信息、下一步打算怎么继续。');
    sb.writeln(
        '   思考是给用户看的，请用和用户提问相同的语言（用户用中文就用中文、用英文就用英文），简洁自然，不要 JSON、不要占位。');
  }
  int idx = includeThinkingGuide ? 2 : 1;
  // 先拼 search（作为基础），再 answer，再剩下的
  ReActPlugin? searchP;
  ReActPlugin? answerP;
  final others = <ReActPlugin>[];
  for (final p in ordered) {
    if (p.triggerType == 'search') {
      searchP = p;
    } else if (p.triggerType == 'answer') {
      answerP = p;
    } else {
      others.add(p);
    }
  }
  if (searchP != null && searchP.metadata.promptProtocol.isNotEmpty) {
    sb.writeln('$idx) ${searchP.metadata.promptProtocol}');
    idx++;
    sb.writeln(
        '${idx - 1}.1) 当你看到对话里出现 <toolresult query="...">...</toolresult>，说明你的 search 已经被执行，这里是搜索结果。继续 <thinking> 分析，或者再发一次 <search query="..." />，或者进入 <answer> / <download> / <ask_user>。');
  }
  // 其他插件（download / ask_user / self_check / 第三方 market 插件）按注册顺序追加
  for (final p in others) {
    if (p.metadata.promptProtocol.isEmpty) continue;
    sb.writeln('$idx) ${p.metadata.promptProtocol}');
    idx++;
  }
  if (answerP != null && answerP.metadata.promptProtocol.isNotEmpty) {
    sb.writeln('$idx) ${answerP.metadata.promptProtocol}');
    idx++;
  }

  final mcpPlugins = ordered
      .where((p) => p.metadata.kind == PluginKind.mcpRemote)
      .toList(growable: false);
  if (mcpPlugins.isNotEmpty) {
    sb.writeln('$idx) MCP 远程工具协议：只能调用下面列出的 plugin_id 和 tool。');
    sb.writeln(
        '   使用 <mcp_call plugin_id="..." tool="...">{"key":"value"}</mcp_call>，arguments 顶层必须是 JSON object。');
    sb.writeln('   工具结果会以消息形式返回；收到后继续 <thinking> 分析、再次调用，或输出 <answer>。');
    const budget = 6000;
    var used = 0;
    for (final plugin in mcpPlugins) {
      final tools = plugin.metadata.extra['tools'];
      if (tools is! List) continue;
      sb.writeln('   plugin_id=${plugin.metadata.id}');
      for (final raw in tools.whereType<Map>()) {
        final tool = Map<String, dynamic>.from(raw);
        final name = tool['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final description = (tool['description']?.toString() ?? '').trim();
        final schema = tool['inputSchema'] ?? tool['input_schema'];
        var schemaText = schema is Map ? jsonEncode(schema) : '{}';
        final full =
            '   - $name: ${description.isEmpty ? "无描述" : description} schema=$schemaText';
        final short =
            '   - $name: ${description.isEmpty ? "无描述" : description} schema={}';
        final line = used + full.length <= budget ? full : short;
        if (used + line.length > budget) continue;
        sb.writeln(line);
        used += line.length;
      }
    }
    idx++;
  }
  sb.writeln();
  sb.writeln('=== 思考轮次 / 时机 ===');
  if (hasSearch) {
    sb.writeln('- 不要不思考就搜索。先写 <thinking>，把"需要搜什么、为什么"说清楚，再出 <search />。');
  }
  sb.writeln(
      '- 不要把最终答案写在 <thinking> 里。<answer>/<download> 之前的所有内容都是"思考过程"，默认折叠显示。');
  if (hasSearch) {
    sb.writeln(
        '- 如果用户的问题完全是常识，不用联网也能回答，就直接 <thinking>说明不需要联网搜索，理由是 XXX</thinking> 然后 <answer>回答</answer>。');
  } else {
    sb.writeln('- 思考完成后，用 <answer>...</answer> 包裹最终回复给用户。');
  }
  if (hasSearch && hasDownload) {
    sb.writeln('- 下载场景强烈建议先搜一次「APP + 官方域名」确认官方下载页是否存在，避免让用户去第三方。');
    sb.writeln('- ⚠️ 用户明确想下载某文件/APP 时，最终必须输出 <download intent="true" .../> 标签（而不是用 <answer> 文字描述下载步骤）。信息不足（如不知道要手机版还是电脑版）时，先用 <ask_user> 反问，问完再输出 <download>。');
  }
  if (hasSearch) {
    sb.writeln('- 你只会看到"纯文本搜索结果"，看不到网页本体，不要假装你访问了一个页面。');
  }
  sb.writeln('- **思考期间用户可能补充信息**：你可能在 <toolresult> 之外看到一条新的 user 消息（用户中途插话）。');
  sb.writeln('  请把它当作对当前任务的补充，自然融入下一步思考，不要把它当成新对话主题另起炉灶。');
  sb.writeln('语言：全程与用户使用同一种语言。');
  return sb.toString();
}

class ApiService extends ChangeNotifier {
  bool _isGenerating = false;
  bool get isGenerating => _isGenerating;

  // v1.3.6：token 用量统计
  int _totalPromptTokens = 0;
  int _totalCompletionTokens = 0;
  int _totalAllTokens = 0;
  int get totalPromptTokens => _totalPromptTokens;
  int get totalCompletionTokens => _totalCompletionTokens;
  int get totalAllTokens => _totalAllTokens;

  void resetTokenCounters() {
    _totalPromptTokens = 0;
    _totalCompletionTokens = 0;
    _totalAllTokens = 0;
  }

  void _accumulateUsage(Map<String, dynamic>? usage) {
    if (usage == null) return;
    final pt = usage['prompt_tokens'] as int?;
    final ct = usage['completion_tokens'] as int?;
    final tt = usage['total_tokens'] as int?;
    if (pt != null) _totalPromptTokens += pt;
    if (ct != null) _totalCompletionTokens += ct;
    if (tt != null) _totalAllTokens += tt;
  }

  // v1.7.9 (M4 修复)：单例 _client/_shouldStop → 并发 streamChat 时第二次调用
  // 覆盖 _client、第一个流的 finally 会 close 掉第二个流的 client（互相掐死）。
  // 改为"活跃流集合"：每次 streamChat 持有自己的 client 和停止标志，
  // stopGeneration 停止全部活跃流，finally 只 close 自己的 client。
  final List<http.Client> _activeClients = [];
  final List<List<bool>> _activeStopFlags = [];

  void stopGeneration() {
    for (final flag in _activeStopFlags) {
      flag[0] = true;
    }
    for (final client in _activeClients) {
      try {
        client.close();
      } catch (_) {}
    }
    LoggerService.instance.info('Generation stopped by user', tag: 'Api');
  }

  /// v1.3.6：构造 API 请求的 messages 数组（多模态支持）
  /// - 有图片附件 → content 为数组（OpenAI vision 格式：
  ///   [{type:text,...},{type:image_url,image_url:{url:"data:mime;base64,..."}}]）
  /// - 有文本/doc 附件 → 把抽取的文本拼到用户正文前面
  /// - 无附件 → content 为纯字符串
  Future<List<Map<String, dynamic>>> _buildMessagesPayload(
    ApiConfig config,
    List<ChatMessage> messages,
  ) async {
    final payload = <Map<String, dynamic>>[];
    if (config.systemPrompt.isNotEmpty) {
      payload.add({'role': 'system', 'content': config.systemPrompt});
    }
    for (final msg in messages) {
      final imgAtts = msg.attachments
          .where((a) => a.type == AttachmentType.image && a.localPath != null)
          .toList();
      final textParts = <String>[];
      for (final a in msg.attachments) {
        if (a.type != AttachmentType.image &&
            a.extractedText != null &&
            a.extractedText!.isNotEmpty) {
          textParts.add('📎 ${a.fileName}:\n${a.extractedText}');
        }
      }
      final baseText = textParts.isEmpty
          ? msg.content
          : '${textParts.join('\n\n')}\n\n${msg.content}';
      if (imgAtts.isNotEmpty) {
        final contentArr = <Map<String, dynamic>>[];
        if (baseText.isNotEmpty) {
          contentArr.add({'type': 'text', 'text': baseText});
        }
        for (final a in imgAtts) {
          try {
            final bytes = await File(a.localPath!).readAsBytes();
            final b64 = base64Encode(bytes);
            final mime = a.mimeType ?? 'image/jpeg';
            contentArr.add({
              'type': 'image_url',
              'image_url': {'url': 'data:$mime;base64,$b64'},
            });
          } catch (e) {
            LoggerService.instance
                .warn('image base64 encode failed: $e', tag: 'Api');
          }
        }
        payload.add({'role': msg.role.value, 'content': contentArr});
      } else {
        payload.add({'role': msg.role.value, 'content': baseText});
      }
    }
    return payload;
  }

  Stream<String> streamChat({
    required ApiConfig config,
    required List<ChatMessage> messages,
    String? reasoningEffort,
    bool yieldReasoning = false,
  }) async* {
    _isGenerating = true;
    notifyListeners();

    final log = LoggerService.instance;
    int chunkCount = 0;
    int totalChars = 0;
    final t0 = DateTime.now();
    // v1.7.9 (M4)：本流私有的 client 与停止标志
    final client = http.Client();
    final stopFlag = <bool>[false];
    _activeClients.add(client);
    _activeStopFlags.add(stopFlag);

    try {
      final url = Uri.parse(config.chatEndpoint);
      final msgList = await _buildMessagesPayload(config, messages);

      final requestBody = json.encode({
        'model': config.model,
        'messages': msgList,
        'temperature': config.temperature,
        'top_p': config.topP,
        'max_tokens': config.maxTokens,
        'stream': true,
        // v1.5.5：ReAct 流式化时传 reasoning_effort（与 completeChat 保持一致）
        if (reasoningEffort != null && reasoningEffort.isNotEmpty)
          'reasoning_effort': reasoningEffort,
        // v1.3.6：启用流式 usage 返回（OpenAI 规范，qwen3-max 等兼容 API 会在最后一个 chunk 带 usage）
        'stream_options': {'include_usage': true},
      });

      log.info(
          'POST $url | model=${config.model} msgs=${msgList.length} temp=${config.temperature} maxTok=${config.maxTokens}',
          tag: 'Api');
      log.verbose(
          '[Api] streamChat request messages:\n${msgList.map((m) {
            final c = m['content'];
            final s = c is String ? c : json.encode(c);
            final cut = s.length > 200 ? '${s.substring(0, 200)}...' : s;
            return '  [${m['role']}] $cut';
          }).join('\n')}',
          tag: 'Api');

      // v1.7.9 (M4)：局部 client，不再覆盖单例字段
      final request = http.Request('POST', url);
      request.headers['Content-Type'] = 'application/json';
      // v1.3.9：本地模型（Ollama / LM Studio）无需 Authorization，
      // apiKey 为空时不发该 header，避免某些本地代理误判 Bearer 而拒绝
      if (config.apiKey.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer ${config.apiKey}';
      }
      request.body = requestBody;

      final response = await client.send(request);
      log.info(
          'Response status=${response.statusCode} length=${response.contentLength ?? "unknown"}',
          tag: 'Api');

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        String errorMsg;
        try {
          final errorJson = json.decode(errorBody);
          errorMsg = errorJson['error']?['message'] ?? errorBody;
        } catch (_) {
          errorMsg = 'HTTP ${response.statusCode}: $errorBody';
        }
        log.error(
            'Stream chat failed: HTTP ${response.statusCode} body=$errorBody',
            tag: 'Api');
        throw Exception(errorMsg);
      }

      final buffer = StringBuffer();
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        if (stopFlag[0]) break;

        buffer.write(chunk);
        final lines = buffer.toString().split('\n');
        buffer.clear();

        // Keep the last incomplete line in buffer
        if (!chunk.endsWith('\n')) {
          buffer.write(lines.removeLast());
        }

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed == 'data: [DONE]