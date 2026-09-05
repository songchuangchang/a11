// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:aichat/services/react_parser.dart';

/// ReAct 标签解析核心规则测试
///
/// 这些测试直接复刻 chat_screen.dart _parseReActOutput 的关键正则，
/// 保障我们修改后 `<thinking>/<search>/<ask_user>/<answer>/<download>/<self_check>`
/// 各种标签解析都不会再次失效（v1.4.1 曾经因为 completeChat 包 <answer> 导致解析失败）。
void main() {
  group('<search> 自闭合标签', () {
    test('基础 query 属性', () {
      final m = RegExp(r'<search\s+([^>]*?)\s*/>', caseSensitive: false)
          .firstMatch('<search query="最新 AI 新闻" />');
      expect(m, isNotNull);
      final q = RegExp(r'query="([^"]+)"').firstMatch(m!.group(1)!);
      expect(q!.group(1), '最新 AI 新闻');
    });

    test('带 depth 属性', () {
      final m = RegExp(r'<search\s+([^>]*?)\s*/>', caseSensitive: false)
          .firstMatch('<search query="weather" depth="advanced" />');
      final d = RegExp(r'depth="(basic|advanced)"').firstMatch(m!.group(1)!);
      expect(d!.group(1), 'advanced');
    });

    test('大小写不敏感', () {
      final m = RegExp(r'<search\s+([^>]*?)\s*/>', caseSensitive: false)
          .firstMatch('<Search Query="test" Depth="BASIC"/>');
      expect(m, isNotNull);
    });
  });

  group('<download> 自闭合标签', () {
    test('带 url 属性（v1.4.2 通用下载）', () {
      final m = RegExp(r'<download\s+([^>]*?)\s*/>', caseSensitive: false)
          .firstMatch(
              '<download url="https://example.com/video.mp4" type="video" />');
      expect(m, isNotNull);
      final attrs = m!.group(1)!;
      final url =
          RegExp('url="([^"]*)"', caseSensitive: false).firstMatch(attrs);
      final type =
          RegExp('type="([^"]*)"', caseSensitive: false).firstMatch(attrs);
      expect(url!.group(1), 'https://example.com/video.mp4');
      expect(type!.group(1), 'video');
    });

    test('带 canonical + platform + keywords', () {
      final m = RegExp(r'<download\s+([^>]*?)\s*/>', caseSensitive: false)
          .firstMatch(
              '<download canonical="WeChat" platform="android" keywords="wechat,微信" intent="true" />');
      final attrs = m!.group(1)!;
      expect(
          RegExp('canonical="([^"]*)"', caseSensitive: false)
              .firstMatch(attrs)!
              .group(1),
          'WeChat');
      expect(
          RegExp('platform="([^"]*)"', caseSensitive: false)
              .firstMatch(attrs)!
              .group(1),
          'android');
    });
  });

  group('<self_check> 自闭合标签', () {
    test('解析 continue / reason', () {
      final m = RegExp(r'<self_check\s+([^>]*?)\s*/>', caseSensitive: false)
          .firstMatch('<self_check continue="false" reason="回答已完成" />');
      final attrs = m!.group(1)!;
      expect(
          RegExp('continue="([^"]*)"', caseSensitive: false)
              .firstMatch(attrs)!
              .group(1),
          'false');
      expect(
          RegExp('reason="([^"]*)"', caseSensitive: false)
              .firstMatch(attrs)!
              .group(1),
          '回答已完成');
    });
  });

  group('<thinking>/<answer>/<ask_user> 配对标签', () {
    test('普通 answer 解析', () {
      const s = '<thinking>思考中...</thinking><answer>你好世界</answer>';
      final answerOpen = s.indexOf('<answer>');
      expect(answerOpen, greaterThan(0));
      final close = s.indexOf('</answer>', answerOpen);
      final content = s.substring(answerOpen + '<answer>'.length, close);
      expect(content, '你好世界');
    });

    test('ask_user 解析（v1.4.1 曾经失效）', () {
      const s = '<thinking>用户信息缺失</thinking><ask_user>请告诉我你的名字</ask_user>';
      final askOpen = s.indexOf('<ask_user>');
      expect(askOpen, greaterThan(0));
      final close = s.indexOf('</ask_user>', askOpen);
      final content = s.substring(askOpen + '<ask_user>'.length, close);
      expect(content, '请告诉我你的名字');
    });
  });

  group('<mcp_call> 配对标签', () {
    test('保留 plugin id、tool 和原始 arguments', () {
      final pieces = parseReActOutput(
        '前置<mcp_call plugin_id="registry-server-name" tool="tool_name">\n{"argument":"value"}\n</mcp_call>',
      );
      expect(pieces, hasLength(2));
      expect(pieces[1], {
        'type': 'mcp_call',
        'pluginId': 'registry-server-name',
        'tool': 'tool_name',
        'arguments': '{"argument":"value"}',
      });
    });

    test('非法空参数不产生调用', () {
      final pieces = parseReActOutput(
        '<MCP_CALL plugin_id="p" tool="t"></MCP_CALL>',
      );
      expect(pieces.where((piece) => piece['type'] == 'mcp_call'), isEmpty);
    });

    test('缺少 plugin_id 或非 object 参数不产生调用', () {
      expect(
        parseReActOutput('<mcp_call tool="t">[]</mcp_call>')
            .where((piece) => piece['type'] == 'mcp_call'),
        isEmpty,
      );
    });

    test('缺少 tool、非法 JSON、标量和 null 参数均不产生调用', () {
      const cases = [
        '<mcp_call plugin_id="p">{"x":1}</mcp_call>',
        '<mcp_call plugin_id="p" tool="t">{"x":</mcp_call>',
        '<mcp_call plugin_id="p" tool="t">1</mcp_call>',
        '<mcp_call plugin_id="p" tool="t">null</mcp_call>',
      ];
      for (final input in cases) {
        expect(
          parseReActOutput(input).where((piece) => piece['type'] == 'mcp_call'),
          isEmpty,
          reason: input,
        );
      }
    });
  });

  group('v1.7.35 回归：思考不得污染结论', () {
    test('thinking 与 answer 分离解析', () {
      final pieces = parseReActOutput(
        '<thinking>第一轮思考</thinking><answer>最终结论</answer>',
      );
      expect(
        pieces.where((piece) => piece['type'] == 'thinking').single['content'],
        '第一轮思考',
      );
      expect(
        pieces.where((piece) => piece['type'] == 'answer').single['content'],
        '最终结论',
      );
    });

    test('原生 think 标签不会成为 answer', () {
      final pieces = parseReActOutput(
        '<think>内部推理</think><answer>公开回答</answer>',
      );
      expect(
        pieces.where((piece) => piece['type'] == 'answer').single['content'],
        '公开回答',
      );
      expect(
        pieces.where((piece) => piece['type'] == 'thinking').single['content'],
        '内部推理',
      );
    });
  });

  group('v1.4.1 回归：answer 不应外包', () {
    test('completeChat 不应无条件包 <answer>', () {
      // 核心回归：如果 AI 响应里已经包含 ReAct 标签（如 <ask_user>），
      // 我们不应该在外层包 <answer>，否则 _parseReActOutput 会把嵌套内容全吞进 answer 块。
      // 见 api_service.dart completeChat 对 ReAct 标签的检测逻辑。
      const contentWithTag =
          '<thinking>我需要更多信息</thinking><ask_user>你叫什么名字？</ask_user>';
      final hasReAct = RegExp(
              r'<\s*(thinking|search|ask_user|download|self_check)\b',
              caseSensitive: false)
          .hasMatch(contentWithTag);
      expect(hasReAct, isTrue, reason: '含 ReAct 标签的内容应该被检测到，不能再包 <answer>');
    });

    test('纯文本 content 才需要包 <answer>', () {
      const plainText = '你好世界';
      final hasReAct = RegExp(
              r'<\s*(thinking|search|ask_user|download|self_check)\b',
              caseSensitive: false)
          .hasMatch(plainText);
      expect(hasReAct, isFalse);
    });
  });
}
