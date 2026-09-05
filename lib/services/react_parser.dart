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
///   - skill_call: <skill_call name="skill.xxx">{optional JSON}</skill_call>  (v1.7.12 新增)
///   - plugin_detail: <plugin_detail name="..." />  (v1.7.17 新增，只读加载插件详情)
///   - mcp_detail  : <mcp_detail plugin_id="..." tool="..." />  (v1.7.17 新增)
///   - skill_detail: <skill_detail name="..." />  (v1.7.17 新增)
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
      // v1.7.16 修复：畸形 <search>（命中标签但缺 query）原来会落到逐字符消费，
      // 把 `<` 写回导致标签被吞成乱码；这里显式跳过整个标签。
      i = searchMatch.end;
      continue;
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

    // <plugin_detail name="..." /> 自闭合（v1.7.17：只读加载插件完整协议）
    final pdMatch = RegExp(
      r'<plugin_detail\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (pdMatch != null) {
      final attrs = pdMatch.group(1) ?? '';
      final nameMatch = RegExp(r'name="([^"]*)"', caseSensitive: false)
          .firstMatch(attrs);
      final name = (nameMatch?.group(1) ?? '').trim();
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      if (name.isNotEmpty) {
        out.add({'type': 'plugin_detail', 'name': name});
      }
      i = pdMatch.end;
      continue;
    }

    // <mcp_detail plugin_id="..." tool="..." /> 自闭合（v1.7.17）
    final mdMatch = RegExp(
      r'<mcp_detail\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (mdMatch != null) {
      final attrs = mdMatch.group(1) ?? '';
      String grab(String k) {
        final m = RegExp('$k="([^"]*)"', caseSensitive: false)
            .firstMatch(attrs);
        return (m?.group(1) ?? '').trim();
      }

      final pluginId = grab('plugin_id');
      final tool = grab('tool');
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      if (pluginId.isNotEmpty && tool.isNotEmpty) {
        out.add({'type': 'mcp_detail', 'pluginId': pluginId, 'tool': tool});
      }
      i = mdMatch.end;
      continue;
    }

    // <skill_detail name="..." /> 自闭合（v1.7.17：只读加载 Skill 完整规则）
    final sdMatch = RegExp(
      r'<skill_detail\s+([^>]*?)\s*/>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (sdMatch != null) {
      final attrs = sdMatch.group(1) ?? '';
      final nameMatch = RegExp(r'name="([^"]*)"', caseSensitive: false)
          .firstMatch(attrs);
      final name = (nameMatch?.group(1) ?? '').trim();
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      if (name.isNotEmpty) {
        out.add({'type': 'skill_detail', 'name': name});
      }
      i = sdMatch.end;
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
    // v1.7.12：<skill_call name="skill.xxx">{optional JSON body}</skill_call>
    // 模仿 mcp_call：配对标签 + 可选 JSON body（body 为空/非法 JSON 也接受，
    // 因为 Skill 本质是 prompt 注入，不需要严格的入参 schema）
    final skillOpen = RegExp(
      r'<skill_call\s+([^>]*?)>',
      caseSensitive: false,
    ).matchAsPrefix(s, i);
    if (skillOpen != null) {
      String grab(String key) {
        final match = RegExp('$key="([^"]*)"', caseSensitive: false)
            .firstMatch(skillOpen.group(1) ?? '');
        return (match?.group(1) ?? '').trim();
      }

      final skillName = grab('name');
      final close = RegExp(r'</skill_call\s*>', caseSensitive: false)
          .firstMatch(s.substring(skillOpen.end));
      final bodyEnd = close == null ? s.length : skillOpen.end + close.start;
      final rawBody = s.substring(skillOpen.end, bodyEnd).trim();
      dynamic decoded;
      try {
        decoded = rawBody.isNotEmpty ? jsonDecode(rawBody) : null;
      } catch (_) {
        decoded = null;
      }
      if (skillName.isNotEmpty) {
        if (buf.isNotEmpty) {
          final t = buf.toString().trim();
          if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
          buf.clear();
        }
        out.add({
          'type': 'skill_call',
          'name': skillName,
          if (decoded is Map)
            'arguments': jsonEncode(Map<String, dynamic>.from(decoded)),
          if (decoded is! Map && rawBody.isNotEmpty) 'content': rawBody,
        });
      } else {
        buf.write(s.substring(i, bodyEnd));
        if (close != null) {
          i = skillOpen.end + close.end;
          continue;
        }
      }
      if (close == null) {
        i = s.length;
        break;
      }
      i = skillOpen.end + close.end;
      continue;
    }
    final thinkMatch = RegExp(r'<(thinking|think)>', caseSensitive: false)
        .firstMatch(s.substring(i));
    final answerMatch =
        RegExp(r'<answer>', caseSensitive: false).firstMatch(s.substring(i));
    final askMatch =
        RegExp(r'<ask_user>', caseSensitive: false).firstMatch(s.substring(i));
    int earliest = 1 << 30;
    String earliestTag = '';
    String openTag = '';
    if (thinkMatch != null && i + thinkMatch.start < earliest) {
      earliest = i + thinkMatch.start;
      earliestTag = 'thinking';
      openTag = thinkMatch.group(0)!;
    }
    if (answerMatch != null && i + answerMatch.start < earliest) {
      earliest = i + answerMatch.start;
      earliestTag = 'answer';
      openTag = answerMatch.group(0)!;
    }
    if (askMatch != null && i + askMatch.start < earliest) {
      earliest = i + askMatch.start;
      earliestTag = 'ask_user';
      openTag = askMatch.group(0)!;
    }
    if (earliestTag.isNotEmpty) {
      final open = earliest;
      final isThink = earliestTag == 'thinking';
      final isAnswer = earliestTag == 'answer';
      final closeTag = isThink
          ? (openTag.toLowerCase() == '<think>' ? '</think>' : '</thinking>')
          : isAnswer
              ? '</answer>'
              : '</ask_user>';
      if (open > i) buf.write(s.substring(i, open));
      if (buf.isNotEmpty) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add({'type': 'thinking', 'content': t});
        buf.clear();
      }
      final closeMatch = RegExp(
        RegExp.escape(closeTag),
        caseSensitive: false,
      ).firstMatch(s.substring(open));
      final tagLen = openTag.length;
      if (closeMatch == null) {
        final body = s.substring(open + tagLen);
        out.add({'type': earliestTag, 'content': body.trim()});
        i = s.length;
        break;
      }
      final close = open + closeMatch.start;
      final body = s.substring(open + tagLen, close);
      out.add({'type': earliestTag, 'content': body.trim()});
      i = close + closeMatch.group(0)!.length;
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
