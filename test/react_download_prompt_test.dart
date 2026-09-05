// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:aichat/services/api_service.dart';
import 'package:aichat/plugins/builtin_plugins.dart';

/// v1.7.13 TDD：ReAct <download> 标签可靠性测试
///
/// 触发背景（nexus_export_2026-08-25T10-51-47 日志）：
///   - 用户首次说"帮我下载个steam"：AI 输出 <ask_user> 反问平台（合理）
///   - 用户选完 iOS / 再说"帮我下载安卓版steam"：AI 仍输出 <answer> 长文（BUG）
///   - 直到第 4 次"安卓14"AI 才输出 <download> 标签
///
/// 根因：原 prompt 措辞"用户明确想下载"留给 AI 自由解读空间，
/// AI 把"帮我下载个steam"解释为"咨询下载方式"而非"执行下载"。
///
/// 本测试要求 prompt 在 hasDownload=true 时包含：
///   1. 明确触发关键词清单（"下载" / "download" / "帮我下" / "安装包" 等）
///   2. 反例：仅"咨询下载方式"才允许 <answer>
///   3. 强调"用户提到下载 + 具体应用名 → 必须输出 <download>"
void main() {
  group('ReAct prompt <download> 标签可靠性', () {
    test('hasDownload=true 时 prompt 必须包含强制 <download> 触发关键词清单', () {
      final plugins = builtinReActPlugins; // 包含 search + download
      final prompt = buildReactSystemPromptFromPlugins(plugins);

      // 必须列出常见下载触发词，让 AI 不再以"不明确"为由给文字答复
      expect(
        prompt,
        contains('下载'),
        reason: 'prompt 必须包含中文触发词「下载」',
      );
      expect(
        prompt.toLowerCase(),
        contains('download'),
        reason: 'prompt 必须包含英文触发词 download',
      );
    });

    test('hasDownload=true 时 prompt 必须明确「用户提到下载+应用名 → 必须输出 <download>」', () {
      final plugins = builtinReActPlugins;
      final prompt = buildReactSystemPromptFromPlugins(plugins);

      // 原措辞"用户明确想下载"太宽松；新措辞必须更强制
      // 关键句：用户提到"下载"或类似意图词 + 具体应用/文件名 → 必须输出 <download>
      expect(
        prompt,
        contains('必须输出'),
        reason: 'prompt 应使用「必须输出」强制语气',
      );
      expect(
        prompt,
        contains('<download'),
        reason: 'prompt 应包含 <download> 标签示例',
      );
      // 新增：明确禁止用 <answer> 描述下载步骤
      expect(
        prompt,
        contains('不要用 <answer>'),
        reason: 'prompt 必须明确禁止用文字答复代替 <download> 标签',
      );
    });

    test('hasDownload=true 时 prompt 必须提供反例区分「咨询」vs「请求下载」', () {
      final plugins = builtinReActPlugins;
      final prompt = buildReactSystemPromptFromPlugins(plugins);

      // 必须给出"什么情况可以用 <answer>"反例，避免 AI 一刀切
      // 例如：「问 Steam 是什么」可走 <answer>；「帮我下载 Steam」必须走 <download>
      expect(
        prompt,
        contains('咨询'),
        reason: 'prompt 必须区分「咨询下载方式」和「请求执行下载」',
      );
    });

    test('搜索结果提示匹配实际 TOOL RESULT START/END 边界', () {
      final prompt = buildReactSystemPromptFromPlugins(builtinReActPlugins);

      expect(prompt, contains('---TOOL RESULT START (search)---'));
      expect(prompt, contains('---TOOL RESULT END (search)---'));
      expect(prompt, isNot(contains('<toolresult query="...">')));
    });

    test('下载平台缺省为 android，仅明确需要选择平台时反问', () {
      final prompt = buildReactSystemPromptFromPlugins(builtinReActPlugins);

      expect(prompt, contains('platform 默认使用 android，不必追问'));
      expect(prompt, contains('只有用户明确要求在 Android、PC 等平台之间选择'));
      expect(prompt, contains('缺少应用名、文件名、URL'));
    });

    test('hasDownload=false 时 prompt 不应包含强制 <download> 触发条款', () {
      // 只启用 search，不启用 download
      final plugins = builtinReActPlugins
          .where((p) => p.triggerType != 'download')
          .toList();
      final prompt = buildReactSystemPromptFromPlugins(plugins);

      // 没启用 download 时，不应包含"必须输出 <download>"
      expect(
        prompt,
        isNot(contains('必须输出 <download')),
        reason: 'download 插件未启用时不应强制输出 <download> 标签',
      );
    });
  });
}
