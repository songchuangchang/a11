import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_message.dart';

class MessageBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isStreaming;
  final String? modelName; // v1.3.6：底部显示模型名

  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.modelName,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  // build 11: 思考过程面板默认折叠（每次新气泡渲染时都保持折叠）
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final isUser = m.role == MessageRole.user;
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // v1.3.6：删除左上角"AI 助手"标签，模型名移到底部与 token 一起显示
            // =================================================================
            // build 11：ReAct 思考过程折叠面板（放在正文前面，默认收起）
            // =================================================================
            if (!isUser && m.hasReasoning)
              _buildReasoningPanel(theme, zh),
            // v1.3.6：📎 附件预览（图片缩略图 + 文件 chip）
            if (m.attachments.isNotEmpty)
              _buildAttachmentPreview(theme, isUser),
            if (m.content.isEmpty && widget.isStreaming)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2,
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    zh ? '思考中...' : 'Thinking...',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarkdownBody(
                    data: _preprocessHtmlDivs(m.content),
                    selectable: !widget.isStreaming,
                    onTapLink: _onTapLink,
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(
                        color: isUser
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurface,
                      ),
                      code: TextStyle(
                        backgroundColor: isUser
                            ? theme.colorScheme.primary.withValues(alpha: 0.3)
                            : theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                        color: isUser
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurface,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      a: TextStyle(color: theme.colorScheme.secondary),
                      // v1.3.7：强制给引用块设置清晰样式，避免 AI 输出的
                      // 蓝色/浅色背景框文字看不清
                      blockquote: TextStyle(
                        color: isUser
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurface,
                        fontSize: 14,
                        height: 1.5,
                      ),
                      blockquoteDecoration: BoxDecoration(
                        color: isUser
                            ? theme.colorScheme.onPrimary.withValues(alpha: 0.12)
                            : theme.colorScheme.primary
                                .withValues(alpha: 0.08),
                        border: Border(
                          left: BorderSide(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.7),
                            width: 3,
                          ),
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                    ),
                  ),
                  // ===== v1.3.1 底部 footnote：淡色小字体 =====
                  if (!isUser &&
                      (m.showStaleFootnote ||
                          m.injectedWebSearchCount > 0 ||
                          m.totalTokens != null ||
                          (widget.modelName != null && widget.modelName!.isNotEmpty)))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 10, runSpacing: 4,
                        children: [
                          if (m.showStaleFootnote)
                            Text(
                              zh
                                  ? '⚠️ 基于 AI 内置知识生成，可能已过时。点击 🌐 可实时联网搜索最新内容。'
                                  : 'Generated from AI training data, may be outdated. Tap 🌐 for live web search.',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.65),
                                height: 1.3,
                              ),
                            ),
                          if (m.injectedWebSearchCount > 0)
                            Text(
                              zh
                                  ? '🌐 已联网注入 ${m.injectedWebSearchCount} 条搜索结果'
                                  : 'Live web search injected ${m.injectedWebSearchCount} results',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.primary
                                    .withValues(alpha: 0.85),
                                height: 1.3,
                              ),
                            ),
                          if (m.totalTokens != null)
                            Text(
                              zh
                                  ? 'Tokens: ${m.totalTokens} (↑${m.promptTokens ?? 0} + ↓${m.completionTokens ?? 0})'
                                  : 'Tokens: ${m.totalTokens} (↑${m.promptTokens ?? 0} + ↓${m.completionTokens ?? 0})',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.55),
                                height: 1.3,
                              ),
                            ),
                          // v1.3.6：模型名显示在底部
                          if (widget.modelName != null && widget.modelName!.isNotEmpty)
                            Text(
                              '🤖 ${widget.modelName}',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.55),
                                height: 1.3,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            if (widget.isStreaming && m.content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '▋',
                  style: TextStyle(
                    color: isUser
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// v1.3.6：📎 附件预览行（图片缩略图 / 文件 chip）
  Widget _buildAttachmentPreview(ThemeData theme, bool isUser) {
    final m = widget.message;
    final onCol =
        isUser ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: m.attachments.map((a) {
          if (a.type == AttachmentType.image && a.localPath != null) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(a.localPath!),
                width: 80,
                height: 80,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 80,
                  height: 80,
                  color: theme.colorScheme.surface,
                  child: Icon(_iconFor(a), color: onCol),
                ),
              ),
            );
          }
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (isUser
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.surface)
                  .withValues(alpha: isUser ? 0.18 : 0.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_iconFor(a), size: 14, color: onCol),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 100),
                  child: Text(
                    a.fileName,
                    style: TextStyle(fontSize: 11, color: onCol),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  IconData _iconFor(MessageAttachment a) {
    switch (a.type) {
      case AttachmentType.image:
        return Icons.image_outlined;
      case AttachmentType.text:
        return Icons.description_outlined;
      case AttachmentType.doc:
        return Icons.article_outlined;
    }
  }

  /// v1.3.7：把 AI 输出的所有带 style 的 HTML 标签彻底剥离，避免出现"浅蓝底白字"等
  /// 对比度不足的渲染结果。策略：
  ///   0) 先按代码围栏 ``` 拆分：代码块内（```...``` 之间的段）原样保留，
  ///      不剥离 HTML 标签，避免 AI 给出的 HTML 示例代码被破坏
  ///   1) 块级元素（div/blockquote/section/aside 等）→ Markdown 引用块（> 内容）
  ///      反复处理 3 轮以应对嵌套
  ///   2) 带 style/color 属性的内联元素（span/font/mark/em/strong/p/h* 等）→
  ///      直接剥离标签，只保留 inner text
  ///   3) 剩余任何带 style 的 HTML 标签 → 剥离标签保留内容
  ///   4) 最后兜底清理所有剩余 HTML 标签（保留 inner text）
  /// 注意：不破坏正常 Markdown 语法（**bold** / `code` / [link]() 等不含 <> 不会被匹配）
  String _preprocessHtmlDivs(String content) {
    // 按 ``` 围栏拆分：偶数索引段在代码块外（需剥离 HTML），奇数索引段在代码块内（原样保留）
    final parts = content.split('```');
    if (parts.length == 1) {
      // 没有代码围栏，直接处理整个内容
      return _stripHtmlTags(content);
    }
    final buf = <String>[];
    for (var i = 0; i < parts.length; i++) {
      buf.add(i.isOdd ? parts[i] : _stripHtmlTags(parts[i]));
    }
    return buf.join('```');
  }

  /// _preprocessHtmlDivs 的内部实现：剥离 HTML 标签。只应作用于代码围栏之外的文本段，
  /// 以免破坏 AI 在 ``` 代码块内给出的 HTML 示例代码。
  String _stripHtmlTags(String content) {
    var result = content;

    // (1) 块级元素 → Markdown 引用块，反复 3 轮处理嵌套
    for (int i = 0; i < 3; i++) {
      final prev = result;
      result = result.replaceAllMapped(
        RegExp(
            r'<(?:div|blockquote|section|aside|figure|article|fieldset|details|summary)[^>]*>([\s\S]*?)</(?:div|blockquote|section|aside|figure|article|fieldset|details|summary)>'),
        (m) {
          final inner = m.group(1)!.trim();
          if (inner.isEmpty) return '';
          return '\n${inner.split('\n').map((l) => '> $l').join('\n')}\n';
        },
      );
      if (result == prev) break;
    }

    // (2) 带 style/color 属性的内联元素 → 剥离标签保留内容
    //     覆盖：span / font / mark / em / strong / b / i / p / code / pre / label / small / sub / sup / u / s / h1-h6
    result = result.replaceAllMapped(
      RegExp(
          r'<(span|font|mark|em|strong|b|i|p|code|pre|label|small|sub|sup|u|s|h[1-6])\s+[^>]*(?:style|color)[^>]*>([\s\S]*?)</\1>'),
      (m) => m.group(2)!.trim(),
    );

    // (3) 兜底：其他带 style 的任意标签 → 剥离标签保留内容
    result = result.replaceAllMapped(
      RegExp(r'<(\w+)[^>]*style="[^"]*"[^>]*>([\s\S]*?)</\1>'),
      (m) => m.group(2)!.trim(),
    );

    // (4) 最后清理：剩余的 <br>、<hr>、自闭合标签等 → 转为对应 Markdown 或移除
    result = result.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    result = result.replaceAll(RegExp(r'<hr\s*/?>', caseSensitive: false), '\n---\n');
    // 移除其他所有剩余 HTML 标签（不破坏 Markdown 协议标签如 <answer>，因为协议标签在
    // _parseReActOutput 阶段已被剥离，到这里通常没有 <...> 形式的内容）
    result = result.replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '');

    return result;
  }

  /// v1.3.6：点击链接弹"复制 / 跳转"选择弹窗
  Future<void> _onTapLink(String text, String? href, String title) async {
    final url = href ?? '';
    if (url.isEmpty) return;
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                url,
                style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    fontFamily: 'monospace'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.open_in_new, color: cs.primary),
              title: Text(isZh ? '在浏览器中打开' : 'Open in browser'),
              onTap: () async {
                Navigator.pop(ctx);
                final uri = Uri.tryParse(url);
                if (uri != null) {
                  await launchUrl(uri,
                      mode: LaunchMode.externalApplication);
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.copy, color: cs.primary),
              title: Text(isZh ? '复制链接' : 'Copy link'),
              onTap: () async {
                Navigator.pop(ctx);
                await Clipboard.setData(ClipboardData(text: url));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text(isZh ? '已复制链接' : 'Link copied'),
                        duration: const Duration(seconds: 1)),
                  );
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.close, color: cs.onSurfaceVariant),
              title: Text(l.tr('cancel')),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReasoningPanel(ThemeData theme, bool zh) {
    final steps = widget.message.reasoningSteps;
    // 统计
    final searchCount = steps.where((s) => s.kind == 'search').length;
    final resultCount = steps
        .where((s) => s.kind == 'search_result')
        .fold<int>(0, (sum, s) => sum + (s.resultCount ?? 0));
    final label = zh
        ? '🧠 思考过程（$searchCount 次搜索，$resultCount 条结果）'
        : '🧠 Reasoning ($searchCount searches, $resultCount results)';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.75),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < steps.length; i++)
                      _buildReasoningStep(steps[i], theme, zh, i),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReasoningStep(
      ReasoningStep s, ThemeData theme, bool zh, int idx) {
    const iconPad = SizedBox(width: 6);
    switch (s.kind) {
      case 'thinking':
        final content = s.content.trim();
        if (content.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.psychology_alt,
                  size: 15,
                  color: theme.colorScheme.tertiary.withValues(alpha: 0.85)),
              iconPad,
              Expanded(
                child: Text(
                  content,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.78),
                    fontStyle: FontStyle.italic,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        );
      case 'search':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.search,
                  size: 15, color: theme.colorScheme.primary),
              iconPad,
              Expanded(
                child: Text(
                  s.content,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      case 'search_result':
        final count = s.resultCount ?? 0;
        final ms = s.latencyMs;
        final line = zh
            ? (ms != null
                ? '✅ 完成：返回 $count 条结果（${ms}ms）'
                : '✅ 完成：返回 $count 条结果')
            : (ms != null
                ? '✅ Done: $count results (${ms}ms)'
                : '✅ Done: $count results');
        return Padding(
          padding: const EdgeInsets.only(left: 20, top: 2, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                line,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: count > 0
                      ? Colors.green
                      : Colors.orange,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (s.content.trim().isNotEmpty && count > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    s.content.trim(),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.6),
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
