// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:aichat/services/logger_service.dart';

/// LoggerService._scrubSensitive / _maskToken 单元测试
///
/// 覆盖：
///   - Authorization: Bearer <token> 各种变体
///   - 通用 apiKey / apikey / api-key
///   - 常见 Key 前缀（sk-/pk-/rk-/xoxb-/ghp-/glm-/deepseek-/ds-/vllm-/qwen-/gsk-/msk-/ant-/claude-/ollama-）
///   - 搜索服务商 Key（tvly/tavily/serpapi/serp/brave/google/bing）
///   - 32+ 字符长 token 兜底
///   - 空字符串 / 边界情况
void main() {
  group('LoggerService._scrubSensitive', () {
    test('空字符串不动', () {
      expect(LoggerService.scrubForTest(''), '');
    });

    test('普通文本不动', () {
      expect(LoggerService.scrubForTest('Hello world, this is a normal message.'),
          'Hello world, this is a normal message.');
    });

    test('Authorization: Bearer 脱敏（无引号）', () {
      final out = LoggerService
          .scrubForTest('Authorization: Bearer sk-abcdef1234567890XYZ');
      expect(out, isNot(contains('sk-abcdef')));
      expect(out, contains('Bearer'));
      expect(out, contains('***'));
    });

    test('Authorization: Bearer 脱敏（带引号、混合大小写）', () {
      final out = LoggerService.scrubForTest(
          '"Authorization" : "Bearer sk-****xxxxyyyy12345678"');
      expect(out, isNot(contains('sk-****')));
      expect(out, contains('Bearer'));
    });

    test('Authorization: Basic 也脱敏', () {
      final out =
          LoggerService.scrubForTest('Authorization: Basic dXNlcjpwYXNzMTIz');
      expect(out, isNot(contains('dXNlcjpwYXNzMTIz')));
      expect(out, contains('Basic'));
    });

    test('apiKey 字段脱敏（= / : 两种分隔符）', () {
      expect(
          LoggerService.scrubForTest('apiKey=sk-****1234567890'),
          isNot(contains('sk-****')),
      );
      expect(
          LoggerService.scrubForTest('"apiKey": "pk-test1234567890abcd"'),
          isNot(contains('pk-test')),
      );
      expect(
          LoggerService.scrubForTest('api-key: rk-abcdef1234567890XYZ'),
          isNot(contains('rk-')),
      );
    });

    test('sk- / pk- / rk- 前缀（4 种）', () {
      for (final prefix in ['sk', 'pk', 'rk', 'xoxb', 'xoxa', 'ghp']) {
        final token = '$prefix-abcdefghij1234567890';
        final out = LoggerService.scrubForTest('token=$token');
        expect(out, isNot(contains(token)), reason: '$prefix- token should be masked');
        expect(out, contains('***'));
      }
    });

    test('云服务商前缀（glm/deepseek/ds/vllm/qwen/gsk/msk/ant/claude/ollama）', () {
      const providers = [
        'glm', 'deepseek', 'ds', 'vllm', 'qwen', 'gsk', 'msk', 'ant', 'claude', 'ollama'
      ];
      for (final p in providers) {
        final token = '$p-xxxxxxxxxxxxxxxxxxxx';
        final out = LoggerService.scrubForTest('token=$token');
        expect(out, isNot(contains(token)), reason: '$p- token should be masked');
      }
    });

    test('搜索服务商 Key（tvly / tavily / serpapi / brave / google / bing）', () {
      const providers = ['tvly', 'tavily', 'serpapi', 'serp', 'brave', 'google', 'bing'];
      for (final p in providers) {
        final token = '${p}_XXXXXXXXXXXXXXXX';
        final out = LoggerService.scrubForTest('key=$token');
        expect(out, isNot(contains(token)), reason: '$p key should be masked');
      }
    });

    test('32 字符以上长 token 兜底', () {
      const long = 'abcdefghijklmnopqrstuvwxyz0123456789';
      final out = LoggerService.scrubForTest('secret=$long');
      expect(out, isNot(contains(long)));
      expect(out, contains('***'));
    });

    test('非 verbose 模式：脱敏后如果仍然超长才截断', () {
      // 注意：600 个 'A' 会被正则 5（32+ 字符长 token）替换为 AAAA***AAAA（11 字符）
      // 因此实际走不到截断逻辑——我们改用带空格的普通长文本来验证截断
      final sb = StringBuffer();
      for (var i = 0; i < 20; i++) {
        sb.writeln('Line $i with some normal text and no sensitive data at all');
      }
      final out = LoggerService.scrubForTest(sb.toString(), truncate: true);
      // 普通文本不脱敏，但会被截断
      expect(out.length, lessThan(sb.toString().length));
      expect(out, contains('[TRUNCATED'));
    });

    test('verbose 模式不截断', () {
      final sb = StringBuffer();
      for (var i = 0; i < 20; i++) {
        sb.writeln('Line $i with some normal text and no sensitive data at all');
      }
      final out = LoggerService.scrubForTest(sb.toString(), truncate: false);
      expect(out.length, equals(sb.toString().length));
    });

    test('混合文本 + 多个敏感字段', () {
      final msg = '''
User asked something.
Headers: Authorization: Bearer sk-****1234567890ABCD
Also: apiKey=pk-xxxxyyyy000011112222
Search key: tvly-abcdef1234567890
''';
      final out = LoggerService.scrubForTest(msg);
      expect(out, isNot(contains('sk-****')));
      expect(out, isNot(contains('pk-xxxx')));
      expect(out, isNot(contains('tvly-abc')));
      expect(out, contains('Bearer'));
    });
  });

  group('LoggerService._maskToken', () {
    test('短 token（<= 8）全部替换为 ***', () {
      expect(LoggerService.maskForTest('short'), '***');
      expect(LoggerService.maskForTest(''), '***');
    });

    test('长 token 保留前 4 后 4', () {
      expect(LoggerService.maskForTest('abcdefghijklmnop'), 'abcd***mnop');
      expect(LoggerService.maskForTest('sk-1234567890'), 'sk-1***7890');
    });
  });
}
