import 'dart:io';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_message.dart';
import '../models/plugin_hint_config.dart';
import 'chat_input_actions.dart';
import 'chat_input_action_button.dart';
import 'chat_input_config.dart';
import 'model_switcher.dart';

/// 聊天输入框（v1.7.18 重构：构造 26 参数 → 5 参数，CC 41→≤15）
///
/// 构造：`{required ChatInputConfig config, required ChatInputActions actions,
/// required TextEditingController controller, required VoidCallback onSend,
/// required VoidCallback onStop}`。
///
/// 布局：
///   [提示条]（3 分支：搜索模式 / 思考中 / 禁用）
///   [🤖模型] [🌐搜索] [🧠思考] [🔌插件]      Spacer      [状态摘要]  ← 按钮行
///   [📎 附件预览 chip 行]
///   [📎] [______________________________] [📤/⏹️]          ← 输入框 + 发送/停止
///
/// v1.7.18 改动：
///   - 需求2：26 参数分组为 ChatInputConfig + ChatInputActions，构造降至 5 参数
///   - 需求5：模型选择区抽出 ModelSwitcher（PopupMenuButton + 清洗名，不截断）
///   - 需求7：🌐/🧠 长按分别跳转联网搜索/自主思考设置页，不再弹 SnackBar
class ChatInput extends StatelessWidget {
  final ChatInputConfig config;
  final ChatInputActions actions;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const ChatInput({
    super.key,
    required this.config,
    required this.actions,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildStatusHintBar(l, cs, isZh),
            _buildButtonRow(context, cs, l, isZh),
            const SizedBox(height: 4),
            _buildAttachmentBar(cs),
            _buildInputRow(l, cs, isZh),
          ],
        ),
      ),
    );
  }

  // ================ 提示条（3 分支）================

  Widget _buildStatusHintBar(
      AppLocalizations l, ColorScheme cs, bool isZh) {
    // 思考队列提示（最高优先级：生成中且有排队的补充消息）
    if (config.isGenerating && config.pendingFollowupCount > 0) {
      return _hintBox(
        isZh
            ? '📩 已加入思考队列 ${config.pendingFollowupCount} 条，AI 下一轮会处理'
            : '📩 Queued for next round: ${config.pendingFollowupCount} message(s)',
        cs.error.withValues(alpha: 0.18),
        cs.error.withValues(alpha: 0.5),
        cs.onSurfaceVariant,
      );
    }
    // 搜索模式提示
    if (config.searchEnabled &&
        config.searchMode &&
        !config.isGenerating) {
      final reactPart = config.reactAutoMode
          ? (isZh
              ? '🌐 ${l.tr('searchModeOn')} · 🧠 自动 · 上限 ${config.reactRounds} 轮'
              : '🌐 ${l.tr('searchModeOn')} · 🧠 Auto · up to ${config.reactRounds} rounds')
          : (isZh
              ? '🌐 ${l.tr('searchModeOn')} · 🧠 ${config.reactLevelLabel} · ${config.reactRounds}轮'
              : '🌐 ${l.tr('searchModeOn')} · 🧠 ${_stripLabel(isZh, config.reactLevelLabel)} · ${config.reactRounds}');
      return _hintBox(
        reactPart + _pluginHintSuffix(isZh),
        cs.tertiaryContainer.withValues(alpha: 0.6),
        cs.tertiary.withValues(alpha: 0.4),
        cs.onTertiaryContainer,
      );
    }
    // 思考中提示
    if (config.isGenerating) {
      return _hintBox(
        isZh
            ? '🧠 思考中… 可继续输入补充信息'
            : '🧠 Thinking... you can type more to add',
        cs.primaryContainer.withValues(alpha: 0.5),
        cs.primary.withValues(alpha: 0.3),
        cs.onPrimaryContainer,
      );
    }
    // 搜索禁用提示
    if (!config.searchEnabled) {
      return _hintBox(
        '⛔ ${l.tr('searchModeDisabled')}',
        cs.outline.withValues(alpha: 0.18),
        cs.outline.withValues(alpha: 0.4),
        cs.onSurfaceVariant,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _hintBox(
      String text, Color bg, Color border, Color fg) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: fg)),
    );
  }

  // ================ 按钮行 ================

  Widget _buildButtonRow(
      BuildContext context, ColorScheme cs, AppLocalizations l, bool isZh) {
    return Row(
      children: [
        // 🤖 模型选择器（需求5）
        ModelSwitcher(
          availableConfigs: config.availableConfigs,
          currentConfig: config.currentConfig,
          onModelChanged: actions.onModelChanged,
          isZh: isZh,
        ),
        // 🌐 搜索
        ActionButton(
          icon: Icons.travel_explore,
          label: '🌐',
          enabled: config.searchEnabled,
          active: config.searchEnabled && config.searchMode,
          tooltip: config.searchEnabled
              ? (config.searchMode
                  ? l.tr('searchModeOn')
                  : l.tr('searchModeOff'))
              : l.tr('searchDisabledHint'),
          onTap: config.isGenerating
              ? null
              : () {
                  if (!config.searchEnabled) {
                    actions.onOpenSearchSettings?.call();
                  } else {
                    actions.onToggleSearch?.call();
                  }
                },
          onLongPress: (config.searchEnabled &&
                  !config.isGenerating &&
                  actions.onLongPressSearch != null)
              ? actions.onLongPressSearch
              : null,
        ),
        // 🧠 思考（v1.7.25：点按弹思考强度细化滑块；长按跳对话设置）
        ActionButton(
          icon: Icons.psychology_alt_outlined,
          label: '🧠',
          badge: config.reactEnabled
              ? (config.reasoningEffort <= 0
                  ? 'DEF'
                  : '${(config.reasoningEffort * 100).round()}%')
              : null,
          enabled: config.reactEnabled,
          active: config.reactEnabled &&
              (config.reactRounds > 0 || config.reactAutoMode),
          tooltip: config.reactEnabled
              ? (isZh
                  ? '思考强度：${reasoningEffortLabel(config.reasoningEffort, true)}'
                  : 'Reasoning effort: ${reasoningEffortLabel(config.reasoningEffort, false)}')
              : (isZh
                  ? '需先打开联网搜索 + 自主思考'
                  : 'Enable web search + autonomous thinking first'),
          onTap: config.isGenerating || !config.reactEnabled
              ? null
              : () => _showReasoningEffortPicker(
                  context, actions, config.reasoningEffort),
          onLongPress: (config.reactEnabled &&
                  !config.isGenerating &&
                  actions.onLongPressReact != null)
              ? actions.onLongPressReact
              : null,
        ),
        // 🔌 插件（v1.7.17 三态）
        ActionButton(
          icon: Icons.extension_outlined,
          label: '🔌',
          enabled: !config.isGenerating,
          active: config.pluginHintMode != PluginHintMode.off,
          badge: _pluginHintBadge(),
          tooltip: _pluginHintTooltip(isZh),
          onTap: config.isGenerating ? null : actions.onTogglePluginHint,
          onLongPress:
              config.isGenerating ? null : actions.onEditPluginHint,
        ),
        const Spacer(),
        // 右侧当前状态摘要
        Text(
          config.reactEnabled
              ? (config.reactAutoMode
                  ? (isZh ? '自动' : 'Auto')
                  : _stripLabel(isZh, config.reactLevelLabel))
              : '',
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  /// 🧠 点按 → 输入框上方弹出思考强度滑块（0.0–1.0，0.1 步进；0=默认/自动）
  Future<void> _showReasoningEffortPicker(BuildContext context,
      ChatInputActions actions, double current) async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    var effort = current;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'reasoning effort',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (ctx, anim1, anim2) => StatefulBuilder(
        builder: (ctx, setSt) => Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            // 面板置于输入框上方（输入框约 84 高），不遮挡打字区
            padding: const EdgeInsets.only(bottom: 92),
            child: Material(
              color: Theme.of(ctx).colorScheme.surfaceContainerHigh,
              elevation: 4,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: MediaQuery.of(ctx).size.width * 0.92,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isZh ? '🧠 思考强度' : '🧠 Reasoning effort',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(ctx).colorScheme.onSurface,
                      ),
                    ),
                    Slider(
                      value: effort.clamp(0.0, 1.0),
                      min: 0,
                      max: 1,
                      divisions: 10,
                      onChanged: (v) => setSt(() {
                        effort = double.parse(v.toStringAsFixed(1));
                      }),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(isZh ? '默认 0.0' : 'Default 0.0',
                            style: const TextStyle(fontSize: 11)),
                        Text(isZh ? '中 0.5' : 'Medium 0.5',
                            style: const TextStyle(fontSize: 11)),
                        Text(isZh ? '高 1.0' : 'High 1.0',
                            style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isZh
                          ? '当前：${reasoningEffortLabel(effort, true)}'
                          : 'Current: ${reasoningEffortLabel(effort, false)}',
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(ctx).colorScheme.primary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (effort != current) actions.onReasoningEffortChanged?.call(effort);
  }

  // ================ 附件预览行 ================

  Widget _buildAttachmentBar(ColorScheme cs) {
    if (config.pendingAttachments.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: config.pendingAttachments
            .map((a) => _buildAttachmentChip(a, cs))
            .toList(),
      ),
    );
  }

  Widget _buildAttachmentChip(MessageAttachment a, ColorScheme cs) {
    final isImg = a.type == AttachmentType.image;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isImg && a.localPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.file(
                File(a.localPath!),
                width: 28,
                height: 28,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Icon(_iconFor(a), size: 18, color: cs.primary),
              ),
            )
          else
            Icon(_iconFor(a), size: 18, color: cs.primary),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              a.fileName,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (actions.onRemoveAttachment != null)
            InkWell(
              onTap: () => actions.onRemoveAttachment!(a),
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child:
                    Icon(Icons.close, size: 14, color: cs.onSurfaceVariant),
              ),
            ),
        ],
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

  // ================ 输入框 + 发送/停止 ================

  Widget _buildInputRow(AppLocalizations l, ColorScheme cs, bool isZh) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 📎 附件按钮
        IconButton(
          onPressed: config.isGenerating ? null : actions.onPickAttachment,
          icon: const Icon(Icons.attach_file, size: 22),
          tooltip:
              isZh ? '添加附件（照片/文档）' : 'Add attachment (photo/document)',
          color: cs.primary,
          visualDensity: VisualDensity.compact,
        ),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            maxLines: 5,
            minLines: 1,
            textInputAction: TextInputAction.newline,
            enabled: true,
            readOnly: false,
            decoration: InputDecoration(
              hintText: config.isGenerating
                  ? (isZh
                      ? '思考中… 可补充信息加入队列'
                      : 'Thinking... type to queue a message')
                  : l.tr('typeAMessage'),
              filled: true,
              fillColor: cs.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) {
              onSend();
            },
          ),
        ),
        const SizedBox(width: 8),
        if (config.isGenerating) ...[
          // 发送按钮（补充消息入队）
          IconButton.filled(
            onPressed: onSend,
            icon: const Icon(Icons.send, size: 20),
            style: IconButton.styleFrom(backgroundColor: cs.primary),
          ),
          const SizedBox(width: 4),
          // 停止按钮
          IconButton(
            onPressed: onStop,
            icon: const Icon(Icons.stop_circle_rounded, size: 24),
            color: cs.error,
            tooltip: isZh ? '停止生成' : 'Stop generating',
          ),
        ] else
          IconButton.filled(
            onPressed: onSend,
            icon: const Icon(Icons.send),
          ),
      ],
    );
  }

  // ================ 插件提示文案辅助 ================

  /// 英文界面下从双语标签 '低 (Low)' 取括号内英文部分
  static String _stripLabel(bool isZh, String label) {
    if (isZh) return label;
    final m = RegExp(r'\(([^)]+)\)').firstMatch(label);
    return m?.group(1) ?? label;
  }

  /// 🔌 蓝色提示条末尾文案（off 空，manual 显示数量，auto 显示「自动」）
  String _pluginHintSuffix(bool isZh) {
    switch (config.pluginHintMode) {
      case PluginHintMode.off:
        return '';
      case PluginHintMode.manual:
        return isZh
            ? ' · 🔌 手动(${config.pluginHintManualCount})'
            : ' · 🔌 Manual(${config.pluginHintManualCount})';
      case PluginHintMode.auto:
        return isZh ? ' · 🔌 自动' : ' · 🔌 Auto';
    }
  }

  /// 🔌 按钮 badge（manual 显示勾选数，auto 显示 AUTO，off 无）
  String? _pluginHintBadge() {
    switch (config.pluginHintMode) {
      case PluginHintMode.off:
        return null;
      case PluginHintMode.manual:
        return '${config.pluginHintManualCount}';
      case PluginHintMode.auto:
        return 'AUTO';
    }
  }

  /// 🔌 按钮 tooltip
  String _pluginHintTooltip(bool isZh) {
    switch (config.pluginHintMode) {
      case PluginHintMode.off:
        return isZh ? '插件提示：关闭' : 'Plugin hint: off';
      case PluginHintMode.manual:
        return isZh
            ? '插件提示：手动（${config.pluginHintManualCount} 项已勾选）'
            : 'Plugin hint: manual (${config.pluginHintManualCount} selected)';
      case PluginHintMode.auto:
        return isZh ? '插件提示：自动' : 'Plugin hint: auto';
    }
  }
}
