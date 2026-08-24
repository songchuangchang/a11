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
          if (trimmed.isEmpty || trimmed == 'data: [DONE]') continue;
          if (!trimmed.startsWith('data:')) continue;

          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') continue;

          try {
            final jsonMap = json.decode(data) as Map<String, dynamic>;
            // v1.3.6：提取 usage（多数 API 在最后一个 chunk 带上 usage）
            if (jsonMap['usage'] != null) {
              _accumulateUsage(jsonMap['usage'] as Map<String, dynamic>);
            }
            final choices = jsonMap['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final delta = choices[0]['delta'] as Map<String, dynamic>?;
              if (delta != null) {
                // v1.5.5：yieldReasoning=true 时，把推理模型的 reasoning_content 也流式 yield，
                // 供 ReAct 循环实时显示思考过程（parseReActOutput 会把它当 thinking）。
                if (yieldReasoning && delta.containsKey('reasoning_content')) {
                  final rc = delta['reasoning_content'] as String?;
                  if (rc != null && rc.isNotEmpty) {
                    chunkCount++;
                    totalChars += rc.length;
                    yield rc;
                  }
                }
                if (delta.containsKey('content')) {
                  final content = delta['content'] as String?;
                  if (content != null && content.isNotEmpty) {
                    chunkCount++;
                    totalChars += content.length;
                    yield content;
                  }
                }
              }
            }
          } catch (e) {
            // Skip malformed JSON chunks
            debugPrint('Parse error: $e');
            log.warn('Malformed SSE chunk skipped: $e', tag: 'Api');
          }
        }
      }
      final ms = DateTime.now().difference(t0).inMilliseconds;
      log.info('Stream done in ${ms}ms, chunks=$chunkCount, chars=$totalChars',
          tag: 'Api');
    } on SocketException catch (e, st) {
      log.error('SocketException during streamChat',
          error: e, stack: st, tag: 'Api');
      throw Exception('Network error: ${e.message}');
    } on HttpException catch (e, st) {
      log.error('HttpException during streamChat',
          error: e, stack: st, tag: 'Api');
      throw Exception('HTTP error: ${e.message}');
    } finally {
      // v1.7.9 (M4)：只清理本流的资源，不影响其他活跃流
      _activeClients.remove(client);
      _activeStopFlags.remove(stopFlag);
      try {
        client.close();
      } catch (_) {}
      if (_activeClients.isEmpty) {
        _isGenerating = false;
      }
      notifyListeners();
    }
  }

  Future<String> testConnection(ApiConfig config) async {
    final log = LoggerService.instance;
    final url = Uri.parse(config.chatEndpoint);
    final requestBody = json.encode({
      'model': config.model,
      'messages': [
        {'role': 'user', 'content': 'Hi'}
      ],
      'max_tokens': 50,
      'stream': false,
    });

    log.info('POST(test) $url | model=${config.model}', tag: 'Api');

    // v1.3.9：本地模型 apiKey 为空时不发 Authorization
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (config.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.apiKey}';
    }
    final response = await http
        .post(
          url,
          headers: headers,
          body: requestBody,
        )
        .timeout(const Duration(seconds: 30));

    log.info(
        'Test response status=${response.statusCode} len=${response.body.length}',
        tag: 'Api');

    if (response.statusCode == 200) {
      final jsonMap = json.decode(response.body) as Map<String, dynamic>;
      // v1.3.7 Bug #3：choices 可能为空数组或字段缺失，做兜底防 RangeError / NPE
      final choices = jsonMap['choices'] as List? ?? [];
      if (choices.isEmpty) {
        throw Exception('服务器返回 200 但 choices 为空');
      }
      // v1.4.2 修复：推理模型（DeepSeek R1 / qwen3 等）会把 token 用在
      // reasoning_content 上，content 可能为空，但连接本身是成功的。
      // 不能因为 content 为空就误判"服务器返回内容为空"。
      final msg = choices[0]['message'] as Map<String, dynamic>? ?? const {};
      final content = msg['content']?.toString() ?? '';
      final reasoning = msg['reasoning_content']?.toString() ?? '';
      if (content.isNotEmpty) return content;
      if (reasoning.isNotEmpty) return reasoning;
      // 连接成功但无可展示文本（纯推理模型 / max_tokens 太小）→ 仍视为成功
      return '连接成功（HTTP 200，响应 ${response.body.length} 字节）';
    } else {
      final errorBody = response.body;
      log.error('Test failed: HTTP ${response.statusCode} body=$errorBody',
          tag: 'Api');
      try {
        final errorJson = json.decode(errorBody);
        throw Exception(errorJson['error']?['message'] ?? errorBody);
      } catch (e) {
        // v1.3.7 Bug #2：FormatException 也是 Exception 子类，会被错误 rethrow
        // 给用户看到 "FormatException: Unexpected character" 而不是 "HTTP 404: ..."
        // 修复：只 rethrow 我们自己 throw 的 Exception；FormatException 走下面 fallback
        if (e is Exception && e is! FormatException) rethrow;
        throw Exception('HTTP ${response.statusCode}: $errorBody');
      }
    }
  }

  // ==========================================================================
  // v1.3.1 build 11: ReAct 循环（AI 自主多轮思考 + 联网搜索）
  // ==========================================================================

  /// ReAct 主系统提示词（模仿 Chatbox 思路：用 <thinking> + <search> + <answer> 协议）
  ///
  /// v1.3.1 build 12 新增：如果用户要「下载安卓 APP / APK」，不要直接写 <answer> 给一堆第三方链接，
  /// 而是输出一个自闭合标签：
  ///   <download intent="true" canonical="APP标准名" platform="android|pc" keywords="kw1,kw2,kw3" domains="d1,d2" />
  ///   - intent="true" 才走下载流程
  ///   - platform: "android"（默认，搜手机 APK）或 "pc"（用户明确要电脑端）
  ///   - canonical: APP 标准名（如 Steam / 微信 / TikTok）
  ///   - keywords: 给搜索引擎的 1~4 个逗号分隔关键词（务必含"android apk 官方"等限定词）
  ///   - domains: 0~2 个你确定的官方/权威域名（白名单，宿主会把这些域名来源升级为 🟢 官方级）
  /// 如果不是下载请求，按原来的思考/搜索流程输出 <answer>。
  ///
  /// v1.3.3 新增：遇到歧义 / 需要用户决策时，AI 可以反向问用户：
  ///   <ask_user>你想问的问题（可选：用 || 分隔多个选项，如：手机端||电脑端||都不要）</ask_user>
  /// 宿主会暂停循环、弹小窗口让用户选/答，用户回复后作为新 user 消息注入，AI 接着思考。
  /// v1.5.0：拉取服务商真实可用模型列表（参考 Chatbox 的 listModels 实现）
  ///
  /// 调用 OpenAI 标准 `GET {baseUrl}/v1/models` 接口，OpenAI 兼容服务都支持。
  /// 返回的 List<String> 是模型 id 列表（如 ['gpt-4o-mini', 'gpt-5.4', ...]）。
  ///
  /// 兼容性：
  ///   - OpenAI / DeepSeek / Kimi / GLM / 通义千问：标准 `data: [{id, ...}]`
  ///   - Ollama 本地：`http://localhost:11434/v1/models` 同样兼容
  ///   - OpenRouter：额外有 `name` 字段（人类可读名），暂不使用只取 id
  ///
  /// 错误处理：网络失败 / 401 / 5xx → 抛异常给调用方处理，UI 层捕获后保留旧 cachedModels
  Future<List<String>> listModels(ApiConfig config) async {
    final log = LoggerService.instance;
    final url = config.modelsEndpoint;
    log.info('GET(models) $url', tag: 'Api');

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    // v1.3.9：本地模型 apiKey 为空时不发 Authorization（Ollama 不需要 Key）
    if (config.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.apiKey}';
    }

    final response = await http
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(seconds: 15));

    log.info(
        'Models response status=${response.statusCode} len=${response.body.length}',
        tag: 'Api');

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} — ${response.reasonPhrase}');
    }

    final jsonMap = json.decode(response.body) as Map<String, dynamic>;
    final data = jsonMap['data'] as List? ?? [];
    if (data.isEmpty) {
      throw Exception('服务器返回 200 但 data 数组为空');
    }

    // 提取 id 字段，过滤掉空字符串
    final models = <String>[];
    for (final item in data) {
      if (item is Map) {
        final id = item['id'];
        if (id is String && id.isNotEmpty) {
          models.add(id);
        }
      }
    }
    // 按字母排序，便于 UI 展示
    models.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return models;
  }

  /// 思考程度 → DeepSeek R1 等原生 reasoning_effort 值；其他模型不支持时就忽略
  /// 对应：关(null) / 低=low（≤2 轮）/ 默认=medium（3 轮）/ 中=medium（≤5 轮）/ 高=high（≤8）/ 极高=high（>8）
  static String? reasoningEffortFromRounds(int rounds) {
    if (rounds <= 0) return null; // 思考循环关 → 不传 reasoning_effort
    if (rounds <= 2) return 'low';
    if (rounds <= 5) return 'medium';
    return 'high';
  }

  /// v1.3.3 新增：根据完整配置决定 reasoning_effort
  /// 自动档统一用 'high'（让 AI 深度思考，自己决定要搜几轮）
  /// 手动档沿用 reasoningEffortFromRounds
  static String? reasoningEffortForConfig(WebSearchConfig cfg) {
    if (cfg.reactAutoMode) return 'high';
    return reasoningEffortFromRounds(cfg.reactMaxRounds);
  }

  // ==========================================================================
  // v1.4.2：token 估算工具方法（用于自动压缩触发判断）
  // ==========================================================================

  /// 粗略估算一组消息的 token 数（按字符数/4 估算，英文约 4 char/token，中文约 1.5 char/token）
  /// 这是估算值，实际 tokenization 因模型而异，但足够用于触发压缩的阈值判断
  static int estimateTokens(List<ChatMessage> messages) {
    int totalChars = 0;
    for (final m in messages) {
      totalChars += m.content.length;
    }
    // 混合中英文平均约 2.5 字符/token，向上取整
    return (totalChars / 2.5).ceil();
  }

  /// 单条消息的 token 估算
  static int estimateMessageTokens(ChatMessage msg) {
    return (msg.content.length / 2.5).ceil();
  }

  /// 非流式完整请求（ReAct 每一轮就是一次 chat.completions 请求）
  /// [reasoningEffort]: 'low' | 'medium' | 'high'（DeepSeek R1 / ChatboxAI API 原生支持）
  Future<String> completeChat({
    required ApiConfig config,
    required List<ChatMessage> messages,
    String? reasoningEffort,
    Map<String, dynamic>? extraBody,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final log = LoggerService.instance;
    final url = Uri.parse(config.chatEndpoint);
    final msgList = await _buildMessagesPayload(config, messages);

    final body = <String, dynamic>{
      'model': config.model,
      'messages': msgList,
      'temperature': config.temperature,
      'top_p': config.topP,
      'max_tokens': config.maxTokens,
      'stream': false,
      if (reasoningEffort != null && reasoningEffort.isNotEmpty)
        'reasoning_effort': reasoningEffort,
    };
    if (extraBody != null) body.addAll(extraBody);

    log.info(
      '[Api] completeChat ${config.model} | msgs=${msgList.length} | '
      'effort=${reasoningEffort ?? '(none)'} | maxTokens=${config.maxTokens}',
      tag: 'Api',
    );
    log.verbose(
        '[Api] completeChat request messages:\n${msgList.map((m) {
          final c = m['content'];
          final s = c is String ? c : json.encode(c);
          final cut = s.length > 300 ? '${s.substring(0, 300)}...' : s;
          return '  [${m['role']}] $cut';
        }).join('\n')}',
        tag: 'Api');
    final resp = await http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            // v1.3.9：本地模型 apiKey 为空时不发 Authorization
            if (config.apiKey.isNotEmpty)
              'Authorization': 'Bearer ${config.apiKey}',
          },
          body: json.encode(body),
        )
        .timeout(timeout);

    if (resp.statusCode != 200) {
      // v1.4.2 安全加固：日志里写完整 body（logger 会自动脱敏），但用户可见错误消息
      // 只展示通用错误描述 + HTTP 状态码，避免在 SnackBar 里泄露上游原始错误体。
      log.error(
          '[Api] completeChat HTTP ${resp.statusCode} body(orig)=${resp.body}',
          tag: 'Api');
      String userMsg;
      try {
        final e = json.decode(resp.body);
        userMsg = e['error']?['message'] ?? 'HTTP ${resp.statusCode}';
      } on Exception catch (_) {
        // 非 JSON 错误体（比如 HTML 登录页 / 502 网关页），不给用户看原始内容
        userMsg = 'HTTP ${resp.statusCode} — 服务端返回了非标准错误（已写入详细日志）';
      }
      throw Exception(userMsg);
    }

    final j = json.decode(resp.body) as Map<String, dynamic>;
    // v1.3.6：提取 token usage
    _accumulateUsage(j['usage'] as Map<String, dynamic>?);
    // v1.6.8 修复 Bug#3：choices 空数组时 .first 抛 StateError（同 testConnection L273 已修过，completeChat 漏修）
    final choices = j['choices'] as List? ?? [];
    if (choices.isEmpty) {
      throw Exception('服务器返回 200 但 choices 为空');
    }
    final message = (choices.first['message'] as Map<String, dynamic>);

    // 兼容 o1 / DeepSeek R1：返回 content 可能是 reasoning_content + content 结构
    final reasoningContent = message['reasoning_content']?.toString() ?? '';
    final content = message['content']?.toString() ?? '';
    log.verbose(
        '[Api] completeChat response: reasoningLen=${reasoningContent.length}, contentLen=${content.length}\n  content(500): ${content.substring(0, content.length > 500 ? 500 : content.length)}',
        tag: 'Api');
    if (reasoningContent.isNotEmpty) {
      // v1.4.1 修复：ReAct 模式下 content 本身就是协议输出（<ask_user>/<search>/<thinking>/<answer>/<download>），
      // 不能再外包 <answer>，否则 _parseReActOutput 会把嵌套内容全吞进 answer 块，导致反问/搜索/循环全失效。
      // 只有 content 是纯文本最终答案（不含任何 ReAct 标签）时才包 <answer>。
      if (content.isEmpty) {
        return '<thinking>$reasoningContent</thinking>';
      }
      // M13 fix: 改用更严格的标签匹配，避免 <thinking_revised> 等变体被误判
      final hasReActTag = RegExp(
        r'<(thinking|search|answer|ask_user|download|self_check|mcp_call)(\s|>|/>)',
        caseSensitive: false,
      ).hasMatch(content);
      if (hasReActTag) {
        return '<thinking>$reasoningContent</thinking>\n$content';
      }
      return '<thinking>$reasoningContent</thinking>\n<answer>$content</answer>';
    }
    return content;
  }

  // ==========================================================================
  // v1.3.1: 让 LLM 判断下载意图（JSON 结构输出），不读数据库、不走 stream
  // 输入：用户原话 输出：Map<String,dynamic>
  //   isDownloadIntent: bool
  //   appNameCanonical: String
  //   searchKeywords: List<String>
  //   officialDomains: List<String>
  //   preferredSources: List<String>
  //   confidence: double 0~1
  // 如果 API 调不通或 JSON 解析失败 → 返回 null（调用方应当回退到纯正则 detectDownloadIntent）
  // ==========================================================================
  Future<Map<String, dynamic>?> judgeDownloadIntentViaLLM(
    ApiConfig config, {
    required String userText,
    int timeoutSeconds = 12,
  }) async {
    final log = LoggerService.instance;
    const systemPrompt =
        '''你是一个"APP 下载意图识别器"。只输出严格合法 JSON，不要 Markdown，不要代码块，不要任何解释文字，只能输出一对大括号 {} 包裹的 JSON。

Schema：
{
  "isDownloadIntent": bool,        // 用户明确要求"下载/获取/安装某个 APP / 安装包"才=true
  "platform": String,              // "android" 或 "pc"（默认 android）
  "appNameCanonical": String,      // APP 的标准名（中文优先，没有则留英文名）
  "searchKeywords": List<String>,  // 给搜索引擎用的 1~4 个关键词
  "officialDomains": List<String>, // 官方域名或可靠的官方下载页域（0~2 个；不确定就空数组）
  "preferredSources": List<String>,  // "内置目录" "GitHub" "官网直链" "第三方应用市场" 中挑，按可信度从高到低排
  "confidence": number            // 0.0 ~ 1.0。不是下载意图就 0
}

规则：
1) 不是"下载 APP/安装包"的请求一律 isDownloadIntent=false。
   - 例："下载一个网站文件/视频/zip"→false。"帮我找微信聊天备份教程"→false。
   - 例："推荐一款安卓阅读器"→false（用户没说下载/安装）。
2) **platform 默认 "android"**：只要用户没明确说要"电脑版/PC 版/Windows 版/Mac 版/桌面版/电脑端/PC 端"，一律 platform="android"，关键词带"安卓 APK 官方"等限定词，搜安卓安装包。
   - 只有当用户原话明确出现上述 PC 字眼，才 platform="pc"，关键词改成"PC 客户端/Windows/Mac"等限定词（不带"安卓/APK"）。
   - 例："下载 Steam" → platform="android", keywords 含 "Steam 安卓 APK"。
   - 例："下载 Steam 电脑版" → platform="pc", keywords 含 "Steam PC 客户端 Windows"。
3) 说的是"下载手机 APP"但不是安卓（iOS 描述）→ isDownloadIntent=false。
4) 关键词里加合适的限定词，减少 GitHub 误命中无关仓库。
5) 如果 APP 有 Gitee/GitHub 官方仓库，域名里填对应地址。
6) steam → 官方域名 store.steampowered.com 或 steamcdn-a.akamaihd.net，不是第三方杂站。
7) 微信→官网 weixin.qq.com；QQ→im.qq.com；钉钉→dingtalk.com；支付宝→alipay.com；抖音→douyin.com；TikTok→tiktok.com；WPS→wps.cn；网易云音乐→music.163.com。
8) 输出除了 JSON 什么都不要写。
''';

    final url = Uri.parse(config.chatEndpoint);
    final body = json.encode({
      'model': config.model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userText},
      ],
      'temperature': 0.1,
      'max_tokens': 500,
      'stream': false,
    });

    log.info(
        '[Intent] LLM judge via=${config.name}/${config.model} textLen=${userText.length}',
        tag: 'API');
    try {
      final resp = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              // v1.3.9：本地模型 apiKey 为空时不发 Authorization
              if (config.apiKey.isNotEmpty)
                'Authorization': 'Bearer ${config.apiKey}',
            },
            body: body,
          )
          .timeout(Duration(seconds: timeoutSeconds));

      if (resp.statusCode != 200) {
        log.warn('[Intent] LLM HTTP ${resp.statusCode}, fallback to regex',
            tag: 'API');
        return null;
      }
      final j = json.decode(resp.body) as Map<String, dynamic>;
      final raw = ((j['choices'] as List?)?.firstOrNull
                  as Map<String, dynamic>?)?['message']?['content']
              ?.toString() ??
          '';
      if (raw.isEmpty) return null;
      log.verbose('[Intent] LLM raw response: $raw', tag: 'API');
      // 防御：去掉 ```json / ``` 包裹
      final clean = raw
          .replaceAllMapped(
              RegExp(r'```(?:json)?\s*', caseSensitive: false), (_) => '')
          .trim();
      // 找最外层 {}
      final s = clean.indexOf('{');
      final e = clean.lastIndexOf('}');
      final slice = (s >= 0 && e > s) ? clean.substring(s, e + 1) : clean;
      final parsed = json.decode(slice);
      if (parsed is Map<String, dynamic>) {
        log.info(
            '[Intent] LLM result: isDl=${parsed['isDownloadIntent']} app=${parsed['appNameCanonical']} kw=${parsed['searchKeywords']}',
            tag: 'API');
        return parsed;
      }
      log.warn('[Intent] LLM result not a JSON object, fallback regex',
          tag: 'API');
      return null;
    } catch (e) {
      log.warn('[Intent] LLM judge failed: $e → fallback regex', tag: 'API');
      return null;
    }
  }
}
