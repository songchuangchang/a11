import 'dart:convert';

/// ReAct 协议输出解析器（v1.4.2 从 chat_screen 抽出为独立纯函数）
///
/// 解析 AI 在「自主联网思考循环 (ReAct)」模式下的协议输出，按出现顺序拆成
/// 若干片段，每个片段带 `type` 标记：
///   - thinking  : 思考过程（<thinking>...</thinking> 或标签外的自由文本）
///   - search    : <search query="..." depth="basic|advanced" />
///   - download  : <download intent=... canonical=... url=... type=... query=... />
///   - self_check: <self_check continue="true|false" reason="..." />
///   - answer    : <answer>...</answer>
///   - ask_user  : <ask_user>...</ask_user>
///   - mcp_call  : <mcp_call plugin_id="..." tool="...">{...}</mcp_call>
///
/// 纯函数、无副作用，可被聊天页和自检服务复用同一套真实逻辑。
List<Map<String, String>> parseReActOutput(String s) {
  final out = <Map<String, String>>[];
  final buf = StringBuffer();
  int i = 0;
  while (i < s.length) {
    // <search query="x" depth="basic|advanced" /> 自闭合（v1.3.4：depth 可选）
    final searchMatch = RegExp(
      r'<search\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (searchMatch != null) {
      final attrs = searchMatch.group(1)!;
      final qMatch = RegExp(r'query="([^"]+)"').firstMatch(attrs);
      if (qMatch != null) {
        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        final piece = <String, String>{
          'type': 'search',
          'content': qMatch.group(1)!.trim(),
        };
        final dMatch = RegExp(r'depth="(basic|advanced)"').firstMatch(attrs);
        if (dMatch != null) piece['depth'] = dMatch.group(1)!;
        out.add(piece);
        i = searchMatch.end;
        continue;
      }
    }

    // <download ... /> 自闭合（v1.4.2：新增 url / type / query 属性）
    final dlMatch = RegExp(
      r'<download\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (dlMatch != null) {
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      final attrs = dlMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      out.add({
        'type': 'download',
        'content': grab('canonical'),
        'keywords': grab('keywords'),
        'domains': grab('domains'),
        'intent': grab('intent'),
        'platform': grab('platform'),
        'url': grab('url'),
        'type_attr': grab('type'),
        'query': grab('query'),
      });
      i = dlMatch.end;
      continue;
    }

    // <self_check continue="true|false" reason="..." /> 自闭合（v1.3.4）
    final scMatch = RegExp(
      r'<self_check\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (scMatch != null) {
      final attrs = scMatch.group(1) ?? '';
      String grab(String k) {
        final m =
            RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      out.add({
        'type': 'self_check',
        'content': grab('reason'),
        'continue': grab('continue'),
      });
      i = scMatch.end;
      continue;
    }

    // <thinking> / <answer> / <ask_user> / <mcp_call> 配对标签
    final mcpOpen = RegExp(
      r'<mcp_call\s+([^>]*?)>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (mcpOpen != null) {
      String grab(String key) {
        final match = RegExp('$key="([^"]*)"', caseSensitive: false)
            .firstMatch(mcpOpen.group(1) ?? '');
        return (match?.group(1) ?? '').trim();
      }

      final pluginId = grab('plugin_id');
      final tool = grab('tool');
      final close = RegExp(r'</mcp_call\s*>', caseSensitive: false)
          .firstMatch(s.substring(mcpOpen.end));
      final bodyEnd = close == null ? s.length : mcpOpen.end + close.start;
      final arguments = s.substring(mcpOpen.end, bodyEnd).trim();
      dynamic decoded;
      try {
        decoded = jsonDecode(arguments);
      } catch (_) {
        decoded = null;
      }
      if (pluginId.isNotEmpty && tool.isNotEmpty && decoded is Map) {
        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        out.add({
          'type': 'mcp_call',
          'pluginId': pluginId,
          'tool': tool,
          'arguments': jsonEncode(Map<String, dynamic>.from(decoded)),
        });
      } else {
        buf.write(s.substring(i, bodyEnd));
        if (close != null) {
          i = mcpOpen.end + close.end;
          continue;
        }
      }
      if (close == null) {
        i = s.length;
        break;
      }
      i = mcpOpen.end + close.end;
      continue;
    }
    final thinkOpen = s.indexOf('<thinking>', i);
    final answerOpen = s.indexOf('<answer>', i);
    final askOpen = s.indexOf('<ask_user>', i);
    int earliest = 1 << 30;
    String earliestTag = '';
    if (thinkOpen != -1 && thinkOpen < earliest) {
      earliest = thinkOpen;
      earliestTag = 'thinking';
    }
    if (answerOpen != -1 && answerOpen < earliest) {
      earliest = answerOpen;
      earliestTag = 'answer';
    }
    if (askOpen != -1 && askOpen < earliest) {
      earliest = askOpen;
      earliestTag = 'ask_user';
    }
    if (earliestTag.isNotEmpty) {
      final open = earliest;
      final isThink = earliestTag == 'thinking';
      final isAnswer = earliestTag == 'answer';
      final closeTag = isThink
          ? '</thinking>'
          : isAnswer
              ? '</answer>'
              : '</ask_user>';
      if (open > i) buf.write(s.substring(i, open));
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      final close = s.indexOf(closeTag, open);
      final tagLen = isThink ? 10 : (isAnswer ? 8 : 10);
      if (close == -1) {
        final body = s.substring(open + tagLen);
        out.add({'type': earliestTag, 'content': body.trim()});
        i = s.length;
        break;
      }
      final body = s.substring(open + tagLen, close);
      out.add({'type': earliestTag, 'content': body.trim()});
      i = close + closeTag.length;
      continue;
    }
    buf.writeCharCode(s.codeUnitAt(i));
    i++;
  }
  if (buf.isNotEmpty) {
    final rest = buf.toString().trim();
    if (rest.isNotEmpty) out.add({'type': 'thinking', 'content': rest});
  }
  return out;
}
