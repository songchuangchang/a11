import 'package:flutter_test/flutter_test.dart';
import 'package:aichat/models/chat_message.dart';
import 'package:aichat/models/web_search_config.dart';
import 'package:aichat/services/api_service.dart';

void main() {
  group('ApiService.reasoningEffortFromRounds', () {
    test('returns null for 0 rounds (disabled)', () {
      expect(ApiService.reasoningEffortFromRounds(0), isNull);
    });

    test('returns null for negative rounds', () {
      expect(ApiService.reasoningEffortFromRounds(-1), isNull);
    });

    test('returns low for 1-2 rounds', () {
      expect(ApiService.reasoningEffortFromRounds(1), 'low');
      expect(ApiService.reasoningEffortFromRounds(2), 'low');
    });

    test('returns medium for 3-5 rounds', () {
      expect(ApiService.reasoningEffortFromRounds(3), 'medium');
      expect(ApiService.reasoningEffortFromRounds(5), 'medium');
    });

    test('returns high for 6+ rounds', () {
      expect(ApiService.reasoningEffortFromRounds(6), 'high');
      expect(ApiService.reasoningEffortFromRounds(10), 'high');
      expect(ApiService.reasoningEffortFromRounds(100), 'high');
    });
  });

  group('ApiService.reasoningEffortForConfig', () {
    test('returns high for auto mode regardless of rounds', () {
      final cfg = WebSearchConfig()..reactAutoMode = true;
      cfg.reactAutoMode = true;
      expect(ApiService.reasoningEffortForConfig(cfg), 'high');
    });

    test('delegates to reasoningEffortFromRounds for manual mode', () {
      final cfg = WebSearchConfig()
        ..reactAutoMode = false
        ..reactMaxRounds = 0;
      expect(ApiService.reasoningEffortForConfig(cfg), isNull);

      final cfg2 = WebSearchConfig()
        ..reactAutoMode = false
        ..reactMaxRounds = 3;
      expect(ApiService.reasoningEffortForConfig(cfg2), 'medium');
    });
  });

  group('ApiService.estimateTokens', () {
    test('returns 0 for empty list', () {
      expect(ApiService.estimateTokens([]), 0);
    });

    test('estimates tokens based on character count', () {
      final msgs = [
        ChatMessage.create(
          conversationId: 'test',
          role: MessageRole.user,
          content: 'Hello',
        ),
      ];
      final tokens = ApiService.estimateTokens(msgs);
      expect(tokens, greaterThan(0));
      expect(tokens, lessThanOrEqualTo(3));
    });

    test('handles multiple messages', () {
      final msgs = [
        ChatMessage.create(
          conversationId: 'test',
          role: MessageRole.user,
          content: 'Hello world',
        ),
        ChatMessage.create(
          conversationId: 'test',
          role: MessageRole.assistant,
          content: 'Hi there, how can I help you?',
        ),
      ];
      final tokens = ApiService.estimateTokens(msgs);
      expect(tokens, greaterThan(0));
    });

    test('handles Chinese text', () {
      final msgs = [
        ChatMessage.create(
          conversationId: 'test',
          role: MessageRole.user,
          content: '你好世界，这是一段中文测试文本',
        ),
      ];
      final tokens = ApiService.estimateTokens(msgs);
      expect(tokens, greaterThan(0));
    });
  });

  group('ApiService.estimateMessageTokens', () {
    test('returns 0 for empty message', () {
      final msg = ChatMessage.create(
        conversationId: 'test',
        role: MessageRole.user,
        content: '',
      );
      expect(ApiService.estimateMessageTokens(msg), 0);
    });

    test('estimates single message tokens', () {
      final msg = ChatMessage.create(
        conversationId: 'test',
        role: MessageRole.user,
        content: 'Hello world',
      );
      final tokens = ApiService.estimateMessageTokens(msg);
      expect(tokens, greaterThan(0));
    });
  });

  group('buildReactSystemPromptFromPlugins', () {
    test('returns prompt without search guidance when no search plugin', () {
      final prompt = buildReactSystemPromptFromPlugins([]);
      expect(prompt, contains('联网搜索已被禁用'));
      expect(prompt, isNot(contains('自主联网思考循环')));
    });

    test('includes thinking guide when requested', () {
      final prompt = buildReactSystemPromptFromPlugins(
        [],
        includeThinkingGuide: true,
      );
      expect(prompt, contains('<thinking>'));
    });

    test('excludes thinking guide when disabled', () {
      final prompt = buildReactSystemPromptFromPlugins(
        [],
        includeThinkingGuide: false,
      );
      expect(prompt, isNot(contains('1) 你写的每一段内部思考')));
    });

    test('includes lazy protocol section', () {
      final prompt = buildReactSystemPromptFromPlugins([]);
      expect(prompt, contains('按需加载协议'));
      expect(prompt, contains('plugin_detail'));
      expect(prompt, contains('mcp_detail'));
      expect(prompt, contains('skill_detail'));
    });

    test('handles empty plugin list gracefully', () {
      final prompt = buildReactSystemPromptFromPlugins([]);
      expect(prompt, isNotEmpty);
      expect(prompt, contains('输出协议'));
    });
  });

  group('ApiService.stopGeneration', () {
    test('stopGeneration sets isGenerating to false', () {
      final service = ApiService();
      service.stopGeneration();
      expect(service.isGenerating, isFalse);
    });
  });
}