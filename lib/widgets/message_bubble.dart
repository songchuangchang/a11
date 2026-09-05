import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_message.dart';
import '../services/biometric_service.dart';
import 'markdown_builders.dart';

class MessageBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isStreaming;
  final String? modelName;
  final VoidCallback? onRetry;
  final int retryVersionCount;
  final int retryVersionIndex;
  final void Function(int direction)? onSwitchVersion;
  final VoidCallback? onRollback;

  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
    this.modelName,
    this.onRetry,
    this.retryVersionCount = 0,
    this.retryVersionIndex = 0,
    this.onSwitchVersion,
    this.onRollback,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  final Set<String> _expandedPhases = {};

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
          border: isUser
              ? null
              : Border.all(
                  color: theme.colorScheme.outlineVariant, width: 1),
          boxShadow: isUser
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary
                        .withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
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
                    // v1.7.37：代码块复制按钮 + 表格复制/下载
                    builders: {
                      'pre': CodeBlockBuilder(),
                      'nx_table': TableBuilder(),
                    },
                    blockSyntaxes: [NexusTableSyntax()],
                    // v1.7.18（需求3）：markdown 样式抽独立方法降 CC
                    styleSheet: _buildMarkdownStyleSheet(theme, isUser),
                  ),
                  // ===== v1.3.1 底部 footnote：淡色小字体 =====
                  // v1.7.18（需求3）：footnote 抽独立方法降 CC
                  if (!isUser && _hasFootnote(m))
                    _buildFootnote(theme, m, zh),
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
            if (!isUser && !widget.isStreaming && widget.onRetry != null)
              _buildRetryRow(theme, zh),
            if (isUser && !widget.isStreaming && widget.onRollback != null)
              _buildRollbackButton(theme, zh),
          ],
        ),
      ),
    );
  }

  /// v1.7.18（需求3）：markdown 渲染样式表（抽自 build 降 CC）
  MarkdownStyleSheet _buildMarkdownStyleSheet(ThemeData theme, bool isUser) {
    final cs = theme.colorScheme;
    return MarkdownStyleSheet(
      p: TextStyle(
        color: isUser ? cs.onPrimary : cs.onSurface,
      ),
      code: TextStyle(
        backgroundColor: isUser
            ? cs.primary.withValues(alpha: 0.3)
            : cs.surfaceContainerHighest.withValues(alpha: 0.5),
        color: isUser ? cs.onPrimary : cs.onSurface,
      ),
      codeblockDecoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      a: TextStyle(color: cs.secondary),
      // v1.3.7：强制给引用块设置清晰样式，避免 AI 输出的蓝色/浅色背景框文字看不清
      blockquote: TextStyle(
        color: isUser ? cs.onPrimary : cs.onSurface,
        fontSize: 14,
        height: 1.5,
      ),
      blockquoteDecoration: BoxDecoration(
        color: isUser
            ? cs.onPrimary.withValues(alpha: 0.12)
            : cs.primary.withValues(alpha: 0.08),
        border: Border(
          left: BorderSide(color: cs.primary.withValues(alpha: 0.7), width: 3),
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
    );
  }

  /// v1.7.18（需求3）：是否需要显示底部 footnote
  bool _hasFootnote(ChatMessage m) {
    return m.showStaleFootnote ||
        m.injectedWebSearchCount > 0 ||
        m.totalTokens != null ||
        (widget.modelName != null && widget.modelName!.isNotEmpty);
  }

  /// v1.7.18（需求3）：底部 footnote 行（过时提示/联网注入/token/模型名）
  Widget _buildFootnote(ThemeData theme, ChatMessage m, bool zh) {
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        children: [
          if (m.showStaleFootnote)
            Text(
              zh
                  ? '⚠️ 基于 AI 内置知识生成，可能已过时。点击 🌐 可实时联网搜索最新内容。'
                  : 'Generated from AI training data, may be outdated. Tap 🌐 for live web search.',
              style: TextStyle(
                fontSize: 10.5,
                color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                height: 1.25,
              ),
            ),
          if (m.injectedWebSearchCount > 0)
            Text(
              zh
                  ? '🌐 已联网注入 ${m.injectedWebSearchCount} 条搜索结果'
                  : 'Live web search injected ${m.injectedWebSearchCount} results',
              style: TextStyle(
                fontSize: 10.5,
                color: cs.primary.withValues(alpha: 0.7),
                height: 1.25,
              ),
            ),
          if (m.totalTokens != null)
            Text(
              'Tokens: ${m.totalTokens} (↑${m.promptTokens ?? 0} + ↓${m.completionTokens ?? 0})',
              style: TextStyle(
                fontSize: 10.5,
                color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                height: 1.25,
              ),
            ),
          if (widget.modelName != null && widget.modelName!.isNotEmpty)
            Text(
              '🤖 ${widget.modelName}',
              style: TextStyle(
                fontSize: 10.5,
                color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                height: 1.25,
              ),
            ),
        ],
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
                  await BiometricService.guardActivityTransition(
                    () => launchUrl(uri,
                        mode: LaunchMode.externalApplication),
                    fallbackDuration: const Duration(seconds: 120),
                  );
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
    // v1.7.29：合并 steps 成可展开节点
    // - thinking → 独立"思考过程"节点
    // - search + 紧邻的 search_result → 配对成"联网查找"节点
    final List<_ReasonNode> nodes = [];
    for (int i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (s.kind == 'search') {
        final result = (i + 1 < steps.length &&
                steps[i + 1].kind == 'search_result')
            ? steps[i + 1]
            : null;
        nodes.add(_ReasonNode(
            type: 'search', step: s, result: result, startIndex: i));
      } else if (s.kind == 'search_result') {
        continue; // 已被前一个 search 节点消费
      } else if (s.kind == 'mcp_call' || s.kind == 'skill_call') {
        nodes.add(_ReasonNode(
            type: s.kind, step: s, result: null, startIndex: i));
      } else {
        nodes.add(_ReasonNode(
            type: 'thinking', step: s, result: null, startIndex: i));
      }
    }

    // 总耗时：首末 step 时间戳跨度
    final totalMs = steps.length >= 2
        ? steps.last.ts.difference(steps.first.ts).inMilliseconds
        : 0;
    final totalLabel = zh
        ? '🧠 思考 ${_fmtSec(totalMs, zh)}'
        : '🧠 Thinking ${_fmtSec(totalMs, zh)}';
    // v1.7.36：流式期间实时计时（每秒刷新），不再等思考完才显示耗时
    final Widget headerLabel = widget.isStreaming && steps.isNotEmpty
        ? _LiveThinkingTimer(startTs: steps.first.ts, zh: zh)
        : Text(
            totalLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );

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
              onTap: () {
                setState(() {
                  if (_expandedPhases.contains('_all')) {
                    _expandedPhases.remove('_all');
                  } else {
                    _expandedPhases.add('_all');
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      _expandedPhases.contains('_all')
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: headerLabel,
                    ),
                  ],
                ),
              ),
            ),
            if (_expandedPhases.contains('_all'))
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < nodes.length; i++)
                      _buildReasoningNode(nodes[i], steps, theme, zh, i),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReasoningNode(
      _ReasonNode n, List<ReasoningStep> steps, ThemeData theme, bool zh, int idx) {
    final key = 'n$idx';
    final isExpanded = _expandedPhases.contains(key);

    // v1.7.29：计算节点耗时（ms）
    // - 联网查找：用 search_result 实测 latencyMs
    // - 思考过程：用下一 step 时间戳差（该轮思考到下一动作的跨度）
    int ms;
    if (n.type == 'search' &&
        n.result != null &&
        n.result!.latencyMs != null) {
      ms = n.result!.latencyMs!;
    } else if (n.startIndex + 1 < steps.length) {
      ms = steps[n.startIndex + 1].ts
          .difference(steps[n.startIndex].ts)
          .inMilliseconds;
    } else {
      ms = 0;
    }

    String label;
    IconData icon;
    Color iconColor;
    if (n.type == 'thinking') {
      label = zh
          ? '💭 思考过程 ${_fmtSec(ms, zh)}'
          : '💭 Thinking ${_fmtSec(ms, zh)}';
      icon = Icons.psychology_alt;
      iconColor = theme.colorScheme.tertiary.withValues(alpha: 0.85);
    } else if (n.type == 'search') {
      final count = n.result?.resultCount ?? 0;
      final ok = count > 0;
      final mark = ok ? '✓' : '✗';
      label = zh
          ? '🔎 联网查找 ${_fmtSec(ms, zh)} $mark'
          : '🔎 Web Search ${_fmtSec(ms, zh)} $mark';
      icon = Icons.search;
      iconColor = ok ? theme.colorScheme.primary : theme.colorScheme.error;
    } else {
      final isMcp = n.type == 'mcp_call';
      final name = n.step.pluginName ?? n.step.pluginId ?? (isMcp ? 'MCP' : 'Skill');
      final target = isMcp ? n.step.toolName : null;
      final status = n.step.status;
      final mark = status == 'running' ? '…' : (status == 'success' || status == 'injected' ? '✓' : '✗');
      label = isMcp
          ? '🔌 MCP · $name${target == null ? '' : ' · $target'} ${_fmtSec(n.step.latencyMs ?? ms, zh)} $mark'
          : '🧩 Skill · $name ${_fmtSec(n.step.latencyMs ?? ms, zh)} $mark';
      icon = isMcp ? Icons.extension_outlined : Icons.auto_awesome_outlined;
      iconColor = status == 'running'
          ? theme.colorScheme.tertiary
          : (status == 'success' || status == 'injected'
              ? theme.colorScheme.primary
              : theme.colorScheme.error);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.5),
          border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                setState(() {
                  if (isExpanded) {
                    _expandedPhases.remove(key);
                  } else {
                    _expandedPhases.add(key);
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      isExpanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Icon(icon, size: 15, color: iconColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (isExpanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: _buildNodeContent(n, theme, zh),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeContent(_ReasonNode n, ThemeData theme, bool zh) {
    if (n.type == 'thinking') {
      final content = n.step.content.trim();
      if (content.isEmpty) return const SizedBox.shrink();
      return Text(
        content,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
          fontStyle: FontStyle.italic,
          height: 1.35,
        ),
      );
    }
    if (n.type == 'mcp_call' || n.type == 'skill_call') {
      final step = n.step;
      final isMcp = n.type == 'mcp_call';
      final statusText = _toolStatusLabel(step.status, zh);
      final statusColor = step.status == 'running'
          ? theme.colorScheme.tertiary
          : (step.status == 'success' || step.status == 'injected'
              ? theme.colorScheme.primary
              : theme.colorScheme.error);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isMcp
                ? '${zh ? '插件' : 'Plugin'}：${step.pluginName ?? step.pluginId ?? '-'}\n${zh ? '工具' : 'Tool'}：${step.toolName ?? '-'}'
                : '${zh ? 'Skill' : 'Skill'}：${step.pluginName ?? step.pluginId ?? '-'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            statusText,
            style: theme.textTheme.labelSmall?.copyWith(
              color: statusColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (step.arguments?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 4),
            Text(
              '${zh ? '参数' : 'Arguments'}\n${step.arguments}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
                fontFamily: 'monospace',
              ),
            ),
          ],
          if (step.resultSummary?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 4),
            _ExpandableSearchResult(
              content: '${zh ? '结果' : 'Result'}\n${step.resultSummary}',
              theme: theme,
              zh: zh,
            ),
          ],
        ],
      );
    }
    // search 节点：搜索动作 + 结果摘要
    final result = n.result;
    final count = result?.resultCount ?? 0;
    final doneLine = result != null
        ? (zh ? '✅ 完成：返回 $count 条结果' : '✅ Done: $count results')
        : (zh ? '✗ 未完成' : '✗ Incomplete');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          n.step.content,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          doneLine,
          style: theme.textTheme.labelSmall?.copyWith(
            color: count > 0
                ? theme.colorScheme.primary
                : theme.colorScheme.error,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (result != null &&
            result.content.trim().isNotEmpty &&
            count > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            // v1.7.31：搜索结果可展开/收起
            child: _ExpandableSearchResult(
              content: result.content.trim(),
              theme: theme,
              zh: zh,
            ),
          ),
      ],
    );
  }

  String _toolStatusLabel(String status, bool zh) {
    switch (status) {
      case 'running':
        return zh ? '⏳ 执行中' : '⏳ Running';
      case 'success':
        return zh ? '✅ 调用成功' : '✅ Succeeded';
      case 'injected':
        return zh ? '✅ Skill 规则已注入' : '✅ Skill rules injected';
      case 'rejected':
        return zh ? '⛔ 用户拒绝' : '⛔ Rejected';
      case 'not_found':
        return zh ? '❌ 未找到' : '❌ Not found';
      case 'invalid':
        return zh ? '⚠️ 参数无效' : '⚠️ Invalid arguments';
      case 'failed':
        return zh ? '❌ 调用失败' : '❌ Failed';
      default:
        return zh ? 'ℹ️ 已记录' : 'ℹ️ Recorded';
    }
  }

  /// v1.7.29：ms 转秒显示（<10s 保留 1 位小数，否则取整）
  String _fmtSec(int ms, bool zh) {
    final s = ms / 1000.0;
    final str = s < 10 ? s.toStringAsFixed(1) : s.round().toString();
    return zh ? '$str 秒' : '${str}s';
  }

  Widget _buildRollbackButton(ThemeData theme, bool zh) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: widget.onRollback,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.undo,
                  size: 14, color: theme.colorScheme.onPrimary.withValues(alpha: 0.7)),
              const SizedBox(width: 3),
              Text(
                zh ? '撤回' : 'Undo',
                style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onPrimary.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRetryRow(ThemeData theme, bool zh) {
    final hasVersions = widget.retryVersionCount > 1;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasVersions)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => widget.onSwitchVersion?.call(-1),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.chevron_left,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (hasVersions) ...[
            const SizedBox(width: 2),
            Text(
              '${widget.retryVersionIndex}/${widget.retryVersionCount}',
              style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 2),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => widget.onSwitchVersion?.call(1),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.chevron_right,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
          ],
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onRetry,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh,
                      size: 14, color: theme.colorScheme.primary),
                  const SizedBox(width: 3),
                  Text(
                    zh ? '重试' : 'Retry',
                    style: TextStyle(
                        fontSize: 11, color: theme.colorScheme.primary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpandableSearchResult extends StatefulWidget {
  final String content;
  final ThemeData theme;
  final bool zh;

  const _ExpandableSearchResult({
    required this.content,
    required this.theme,
    required this.zh,
  });

  @override
  State<_ExpandableSearchResult> createState() =>
      _ExpandableSearchResultState();
}

class _ExpandableSearchResultState extends State<_ExpandableSearchResult> {
  bool _expanded = false;

  /// v1.7.37：解析 `[n] 标题` + `URL: xxx` 行，产出可点/可复制的来源列表
  List<({String index, String title, String url})> _parseSources() {
    final sources = <({String index, String title, String url})>[];
    final titleRe = RegExp(r'^\s*\[(\d+)\]\s*(.*)$');
    final urlRe = RegExp(r'^\s*URL:\s*(\S+)\s*$', caseSensitive: false);
    String? curIndex;
    String? curTitle;
    for (final line in widget.content.split('\n')) {
      final tm = titleRe.firstMatch(line);
      final um = urlRe.firstMatch(line);
      if (tm != null) {
        curIndex = tm.group(1);
        curTitle = tm.group(2) ?? '';
      } else if (um != null && curIndex != null) {
        final url = um.group(1)!;
        if (url.startsWith('http')) {
          sources.add((
            index: curIndex,
            title: (curTitle == null || curTitle.isEmpty) ? url : curTitle,
            url: url,
          ));
        }
        curIndex = null;
        curTitle = null;
      }
    }
    return sources;
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(widget.zh ? '已复制链接' : 'Link copied'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = widget.theme.textTheme.bodySmall?.copyWith(
      color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.6),
      fontSize: 11,
    );
    final sources = _parseSources();
    // 解析失败（没有 URL 行）→ 回退原纯文本渲染
    if (sources.isEmpty) {
      return GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.content,
              maxLines: _expanded ? null : 3,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: textStyle,
            ),
            Text(
              _expanded
                  ? (widget.zh ? '收起' : 'Show less')
                  : (widget.zh ? '展开全部' : 'Show all'),
              style: widget.theme.textTheme.labelSmall?.copyWith(
                color: widget.theme.colorScheme.primary,
                fontSize: 10,
              ),
            ),
          ],
        ),
      );
    }

    // 解析成功：每条来源一行（序号+标题+打开/复制按钮）
    // 内层 InkWell 的手势识别器在竞技场中优先获胜，不会误触外层展开/收起
    const collapsedCount = 2;
    final visible =
        _expanded ? sources : sources.take(collapsedCount).toList();
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in visible)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '[${s.index}] ${s.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle,
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _openUrl(s.url),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.open_in_new,
                        size: 13,
                        color: widget.theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _copyUrl(s.url),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.copy,
                        size: 13,
                        color: widget.theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (sources.length > collapsedCount)
            Text(
              _expanded
                  ? (widget.zh ? '收起' : 'Show less')
                  : (widget.zh
                      ? '展开全部（${sources.length} 条）'
                      : 'Show all (${sources.length})'),
              style: widget.theme.textTheme.labelSmall?.copyWith(
                color: widget.theme.colorScheme.primary,
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }
}

class _ReasonNode {
  final String type; // 'thinking' | 'search'
  final ReasoningStep step;
  final ReasoningStep? result; // search 节点配对的 search_result
  final int startIndex; // 在原 steps 中的起始索引（算耗时用）
  const _ReasonNode({
    required this.type,
    required this.step,
    this.result,
    required this.startIndex,
  });
}

/// v1.7.36：流式期间思考面板实时计时器（每秒刷新一次）
class _LiveThinkingTimer extends StatefulWidget {
  final DateTime startTs;
  final bool zh;
  const _LiveThinkingTimer({required this.startTs, required this.zh});

  @override
  State<_LiveThinkingTimer> createState() => _LiveThinkingTimerState();
}

class _LiveThinkingTimerState extends State<_LiveThinkingTimer> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ms = DateTime.now().difference(widget.startTs).inMilliseconds;
    final s = ms / 1000.0;
    final str = s < 10 ? s.toStringAsFixed(1) : s.round().toString();
    final label = widget.zh ? '🧠 思考中 $str 秒' : '🧠 Thinking ${str}s';
    final theme = Theme.of(context);
    return Text(
      label,
      style: theme.textTheme.bodySmall?.copyWith(
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.primary,
      ),
    );
  }
}
