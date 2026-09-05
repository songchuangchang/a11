// v1.7.34：子代理编排标签解析器单测
//
// 目标：验证 agent_parser.dart 里 4 个纯函数的边界行为，
// 这些函数在 AI 输出"脏数据"时不能崩，也不能把非法 target 漏进去。

import 'package:flutter_test/flutter_test.dart';
import 'package:aichat/services/agent_parser.dart';

void main() {
  group('parseRouteTag', () {
    test('4 valid targets all accepted', () {
      for (final t in ['self', 'search', 'synthesis', 'plugin']) {
        final r = parseRouteTag('<route target="$t" reason="unit test"/>');
        expect(r.target, t);
        expect(r.reason, 'unit test');
      }
    });

    test('case-insensitive, lowercased output', () {
      final r = parseRouteTag('<route target="SEARCH" reason="X"/>');
      expect(r.target, 'search');
    });

    test('attribute order swapped still matches', () {
      final r = parseRouteTag('<route reason="Y" target="plugin"/>');
      expect(r.target, 'plugin');
      expect(r.reason, 'Y');
    });

    test('no tag → fallback self', () {
      final r = parseRouteTag('AI 想直接答，没有标签');
      expect(r.target, 'self');
      expect(r.reason, 'no <route> tag');
    });

    test('empty raw → fallback self', () {
      final r = parseRouteTag('');
      expect(r.target, 'self');
    });

    test('invalid target (e.g. "weather") → fallback self', () {
      final r = parseRouteTag('<route target="weather" reason="unknown"/>');
      expect(r.target, 'self');
      expect(r.reason, 'unknown');
    });

    test('missing reason is empty string', () {
      final r = parseRouteTag('<route target="self"/>');
      expect(r.target, 'self');
      expect(r.reason, '');
    });

    test('tag in middle of text still matches', () {
      final r = parseRouteTag('Thinking...\n<route target="search" reason="fresh news"/>\n...');
      expect(r.target, 'search');
    });

    test('empty target falls back to self', () {
      final r = parseRouteTag('<route target="" reason="broken"/>');
      // empty string not in validTargets → self
      expect(r.target, 'self');
    });
  });

  group('stripAnswerTag', () {
    test('with tag → return inner trimmed', () {
      expect(stripAnswerTag('<answer>你好</answer>'), '你好');
    });

    test('no tag → original trimmed', () {
      expect(stripAnswerTag('  hello  '), 'hello');
    });

    test('multi-line inner content preserved', () {
      final raw = '<answer>\nLine 1\nLine 2\n</answer>';
      expect(stripAnswerTag(raw), 'Line 1\nLine 2');
    });

    test('multiple tags → first one wins (non-greedy)', () {
      final r = stripAnswerTag('<answer>first</answer> junk <answer>second</answer>');
      expect(r, 'first');
    });

    test('empty answer tag → empty string', () {
      expect(stripAnswerTag('<answer></answer>'), '');
    });
  });

  group('extractQueries', () {
    test('1 to 5 queries in <queries> block', () {
      for (var n = 1; n <= 5; n++) {
        final qs = List.generate(n, (i) => '<query>q$i</query>').join('');
        final raw = '<queries>$qs</queries>';
        final out = extractQueries(raw);
        expect(out.length, n, reason: 'n=$n');
      }
    });

    test('more than 5 → truncate to 5', () {
      final qs = List.generate(8, (i) => '<query>q$i</query>').join('');
      final out = extractQueries('<queries>$qs</queries>');
      expect(out.length, 5);
      expect(out.first, 'q0');
      expect(out.last, 'q4');
    });

    test('no <queries> outer tag → scan whole text', () {
      final out = extractQueries('<query>only</query>');
      expect(out, ['only']);
    });

    test('empty <query></query> is discarded', () {
      final out = extractQueries(
          '<queries><query>good</query><query>   </query></queries>');
      expect(out, ['good']);
    });

    test('no tags at all → empty list', () {
      expect(extractQueries('no tags here'), isEmpty);
    });

    test('empty raw → empty list', () {
      expect(extractQueries(''), isEmpty);
    });

    test('query content is trimmed', () {
      final out = extractQueries(
          '<queries>\n  <query>   AI 大模型排名   </query>\n</queries>');
      expect(out, ['AI 大模型排名']);
    });
  });

  group('extractSynthesis', () {
    test('with tag → inner trimmed', () {
      expect(extractSynthesis('<synthesis>result</synthesis>'), 'result');
    });

    test('no tag → original trimmed', () {
      expect(extractSynthesis('plain text  '), 'plain text');
    });

    test('multi-section body preserved', () {
      final raw = '<synthesis>\n## 结论\n点1\n\n## 证据\n- A\n\n## 分歧\n无\n</synthesis>';
      final out = extractSynthesis(raw);
      expect(out.contains('## 结论'), isTrue);
      expect(out.contains('## 证据'), isTrue);
      expect(out.contains('## 分歧'), isTrue);
    });
  });

  group('checkSynthesisSections', () {
    test('zh all three sections present', () {
      final body = '## 结论\n...\n\n## 证据\n...\n\n## 分歧与不确定性\n...';
      final r = checkSynthesisSections(body, isZh: true);
      expect(r.conclusion, isTrue);
      expect(r.evidence, isTrue);
      expect(r.disagree, isTrue);
    });

    test('zh disagree via "不确定性" keyword matches', () {
      final body = '## 结论\n## 证据\n存在不确定性';
      final r = checkSynthesisSections(body, isZh: true);
      expect(r.disagree, isTrue);
    });



    test('en all three sections present', () {
      final body = '## Conclusion\n...\n## Evidence\n...\n## Disagreements & Uncertainty\n...';
      final r = checkSynthesisSections(body, isZh: false);
      expect(r.conclusion, isTrue);
      expect(r.evidence, isTrue);
      expect(r.disagree, isTrue);
    });

    test('en case-insensitive', () {
      final body = 'CONCLUSION\nEVIDENCE\ndisagreement';
      final r = checkSynthesisSections(body, isZh: false);
      expect(r.conclusion, isTrue);
      expect(r.evidence, isTrue);
      expect(r.disagree, isTrue);
    });

    test('missing sections → false', () {
      // 用不含"结论/证据/分歧/不确定性"关键词的正文
      final body = '## 总结\n本分析仅基于常识，未列出任何资料。';
      final r = checkSynthesisSections(body, isZh: true);
      expect(r.conclusion, isFalse);
      expect(r.evidence, isFalse);
      expect(r.disagree, isFalse);
    });

    test('partial: only 结论 present', () {
      final body = '## 结论\n要点 A\n\n## 附注\n（此格式仅示例，无其它关键词）';
      final r = checkSynthesisSections(body, isZh: true);
      expect(r.conclusion, isTrue);
      expect(r.evidence, isFalse);
      expect(r.disagree, isFalse);
    });

    test('empty body → all false', () {
      final r = checkSynthesisSections('', isZh: true);
      expect(r.conclusion, isFalse);
      expect(r.evidence, isFalse);
      expect(r.disagree, isFalse);
    });
  });
}
