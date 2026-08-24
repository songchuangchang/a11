import 'dart:io';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_message.dart';
import '../models/api_config.dart';
import '../screens/settings_screen.dart';

/// 聊天输入框（v1.3.5：按钮移到输入框上方，解决堆叠问题）
///
/// 布局：
///   [提示条]
///   [🌐 搜索] [🧠 思考]                      ← 按钮行（紧凑排列）
///   [______________________________] [📤/⏹️]  ← 输入框 + 发送/停止
///
/// v1.4.0 改动：
///   - ⏱️ 20 秒防卡壳按钮移除，改到聊天页右上角"对话设置"里（默认开启）
/// v1.3.5 改动：
///   - 三个按钮移到输入框上方独立行，不再挤压输入框
///   - 思考中发送按钮保留（可发补充消息入队）+ 独立停止按钮
class ChatInput extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final bool isGenerating;

  // -------- 🌐 --------
  final bool searchMode;
  final bool searchEnabled;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onOpenSearchSettings;
  final VoidCallback? onLongPressOpenSettings;

  // -------- 🧠 --------
  final int reactRounds;
  final String reactLevelLabel;
  final bool reactEnabled;
  final VoidCallback? onCycleReactLevel;
  final bool reactAutoMode;

  // -------- 思考队列 --------
  final int pendingFollowupCount;

  // -------- 🤖 模型选择（v1.6.0）--------
  final ValueChanged<ApiConfig>? onModelChanged;
  final List<ApiConfig> availableConfigs;
  final ApiConfig? currentConfig;

  // -------- 📎 附件（v1.3.6）--------
  final List<MessageAttachment> pendingAttachments;
  final VoidCallback? onPickAttachment;
  final void Function(MessageAttachment)? onRemoveAttachment;

  const ChatInput({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onStop,
    this.isGenerating = false,
    this.searchMode = false,
    this.searchEnabled = true,
    this.onToggleSearch,
    this.onOpenSearchSettings,
    this.onLongPressOpenSettings,
    this.reactRounds = 3,
    this.reactLevelLabel = '中 (Medium)',
    this.reactEnabled = true,
    this.onCycleReactLevel,
    this.reactAutoMode = false,
    this.pendingFollowupCount = 0,
    this.onModelChanged,
    this.availableConfigs = const [],
    this.currentConfig,
    this.pendingAttachments = const [],
    this.onPickAttachment,
    this.onRemoveAttachment,
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
            // 思考队列提示
            if (isGenerating && pendingFollowupCount > 0)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.deepOrangeAccent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: Colors.deepOrangeAccent.withValues(alpha: 0.5)),
                ),
                child: Text(
                  isZh
                      ? '📩 已加入思考队列 $pendingFollowupCount 条，AI 下一轮会处理'
                      : '📩 Queued for next round: $pendingFollowupCount message(s)',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            // 搜索模式 / 思考中 / 禁用 提示条
            if (searchEnabled && searchMode && !isGenerating)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.tertiary.withValues(alpha: 0.4)),
                ),
                child: Text(
                  reactAutoMode
                      ? (isZh
                          ? '🌐 ${l.tr('searchModeOn')} · 🧠 自动 · 上限 $reactRounds 轮'
                          : '🌐 ${l.tr('searchModeOn')} · 🧠 Auto · up to $reactRounds rounds')
                      : (isZh
                          ? '🌐 ${l.tr('searchModeOn')} · 🧠 $reactLevelLabel · $reactRounds轮'
                          : '🌐 ${l.tr('searchModeOn')} · 🧠 ${_stripLabel(isZh, reactLevelLabel)} · $reactRounds'),
                  style: TextStyle(fontSize: 11, color: cs.onTertiaryContainer),
                ),
              )
            else if (isGenerating)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
                ),
                child: Text(
                  isZh ? '🧠 思考中… 可继续输入补充信息' : '🧠 Thinking... you can type more to add',
                  style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer),
                ),
              )
            else if (!searchEnabled)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.4)),
                ),
                child: Text(
                  '⛔ ${l.tr('searchModeDisabled')}',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            // 按钮行：🤖模型 🌐 🧠 紧凑排列
            Row(
              children: [
                _buildModelSelector(context, cs, isZh),
                _buildCompactToggle(
                  context,
                  icon: Icons.travel_explore,
                  label: '🌐',
                  enabled: searchEnabled,
                  active: searchEnabled && searchMode,
                  tooltip: searchEnabled
                      ? '${searchMode ? l.tr('searchModeOn') : l.tr('searchModeOff')}'
                      : l.tr('searchDisabledHint'),
                  onTap: isGenerating
                      ? null
                      : () {
                          if (!searchEnabled) {
                            onOpenSearchSettings?.call();
                          } else {
                            onToggleSearch?.call();
                          }
                        },
                  onLongPress: searchEnabled && !isGenerating && onLongPressOpenSettings != null
                      ? onLongPressOpenSettings
                      : null,
                ),
                _buildCompactToggle(
                  context,
                  icon: Icons.psychology_alt_outlined,
                  label: '🧠',
                  badge: reactEnabled
                      ? (reactAutoMode ? 'AUTO' : '$reactRounds')
                      : null,
                  enabled: reactEnabled,
                  active: reactEnabled && (reactRounds > 0 || reactAutoMode),
                  tooltip: reactEnabled
                      ? (isZh
                          ? '思考程度：$reactLevelLabel'
                                '${reactAutoMode ? "（上限 $reactRounds 轮）" : "（$reactRounds轮）"}'
                          : 'Thinking level: ${_stripLabel(isZh, reactLevelLabel)}'
                                '${reactAutoMode ? " (up to $reactRounds rounds)" : " ($reactRounds)"}')
                      : (isZh ? '需先在设置中打开联网搜索 + 自主思考' : 'Enable web search + autonomous thinking in Settings first'),
                  onTap: isGenerating || !reactEnabled
                      ? null
                      : onCycleReactLevel,
                  onLongPress: reactEnabled && !isGenerating && onLongPressOpenSettings != null
                      ? onLongPressOpenSettings
                      : null,
                ),
                const Spacer(),
                // 右侧显示当前状态摘要
                Text(
                  reactEnabled
                      ? (reactAutoMode
                          ? (isZh ? '自动' : 'Auto')
                          : _stripLabel(isZh, reactLevelLabel))
                      : '',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // v1.3.6：已选附件预览（缩略图 / 文件名 + ×）
            if (pendingAttachments.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: pendingAttachments
                      .map((a) => _buildAttachmentChip(a, cs))
                      .toList(),
                ),
              ),
            // 输入框 + 📎 + 发送/停止按钮
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // v1.3.6：📎 附件按钮（点开选 相册/拍照/文档）
                IconButton(
                  onPressed: isGenerating ? null : onPickAttachment,
                  icon: const Icon(Icons.attach_file, size: 22),
                  tooltip: isZh ? '添加附件（照片/文档）' : 'Add attachment (photo/document)',
                  color: cs.primary,
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.newline,
                    enabled: true,
                    decoration: InputDecoration(
                      hintText: isGenerating
                          ? (isZh ? '思考中… 可补充信息加入队列' : 'Thinking... type to queue a message')
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
                // v1.3.5：思考中同时显示发送+停止，不再只有停止按钮
                if (isGenerating) ...[
                  // 发送按钮（补充消息入队）
                  IconButton.filled(
                    onPressed: onSend,
                    icon: const Icon(Icons.send, size: 20),
                    style: IconButton.styleFrom(
                      backgroundColor: cs.primary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // 停止按钮
                  IconButton(
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_circle_rounded, size: 24),
                    color: Colors.red,
                    tooltip: isZh ? '停止生成' : 'Stop generating',
                  ),
                ] else
                  IconButton.filled(
                    onPressed: onSend,
                    icon: const Icon(Icons.send),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// v1.6.6：英文界面下从双语标签 '低 (Low)' 中取括号内英文部分
  static String _stripLabel(bool isZh, String label) {
    if (isZh) return label;
    final m = RegExp(r'\(([^)]+)\)').firstMatch(label);
    return m?.group(1) ?? label;
  }

  /// 紧凑型切换按钮（图标 + emoji 标签，比 IconButton 更小）
  Widget _buildCompactToggle(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool enabled,
    required bool active,
    required String tooltip,
    String? badge,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final cs = Theme.of(context).colorScheme;
    // v1.3.6：去掉 Tooltip 白色弹窗
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? cs.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: active
              ? Border.all(color: cs.primary.withValues(alpha: 0.4))
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: !enabled
                      ? Colors.grey
                      : active
                          ? cs.primary
                          : cs.onSurfaceVariant,
                ),
                  if (badge != null)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0),
                        decoration: BoxDecoration(
                          color: active ? cs.primary : Colors.deepOrangeAccent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        constraints: const BoxConstraints(minWidth: 14),
                        alignment: Alignment.center,
                        child: Text(
                          badge,
                          style: TextStyle(
                            fontSize: badge.length > 2 ? 6.5 : 8,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: !enabled
                      ? Colors.grey
                      : active
                          ? cs.primary
                          : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
  }

  /// v1.3.6：已选附件 chip（图片缩略图 / 文件图标 + 名 + ×）
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
          if (onRemoveAttachment != null)
            InkWell(
              onTap: () => onRemoveAttachment!(a),
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.close, size: 14, color: cs.onSurfaceVariant),
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

  /// v1.6.0：🤖 模型选择器（Chip 风格，与现有按钮尺寸一致）
  Widget _buildModelSelector(
    BuildContext context,
    ColorScheme cs,
    bool isZh,
  ) {
    final cfg = currentConfig;
    final hasConfigs = availableConfigs.isNotEmpty;
    final displayLabel = cfg != null
        ? '${cfg.name} (${cfg.model})'
        : (isZh ? '未选模型' : 'No model');

    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: hasConfigs
            ? cs.primary.withValues(alpha: 0.10)
            : Colors.grey.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: hasConfigs
            ? Border.all(color: cs.primary.withValues(alpha: 0.35))
            : Border.all(color: Colors.grey.withValues(alpha: 0.35)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ApiConfig>(
          value: hasConfigs && cfg != null && availableConfigs.contains(cfg)
              ? cfg
              : null,
          isDense: true,
          itemHeight: null,
          icon: Icon(
            Icons.arrow_drop_down,
            size: 16,
            color: hasConfigs ? cs.primary : Colors.grey,
          ),
          selectedItemBuilder: (_) => availableConfigs
              .map((c) => DropdownMenuItem<ApiConfig>(
                    value: c,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('🤖', style: TextStyle(fontSize: 12)),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 100),
                          child: Text(
                            c.name,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.primary,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ))
              .toList(),
          items: [
            ...availableConfigs.map(
              (c) => DropdownMenuItem<ApiConfig>(
                value: c,
                child: Row(
                  children: [
                    const Text('🤖', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${c.name} (${c.model})',
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            DropdownMenuItem<ApiConfig>(
              enabled: false,
              child: Divider(
                height: 1,
                color: cs.outlineVariant,
              ),
            ),
            DropdownMenuItem<ApiConfig>(
              value: null,
              onTap: () {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SettingsScreen(),
                    ),
                  );
                });
              },
              child: Row(
                children: [
                  Icon(
                    Icons.add_circle_outline,
                    size: 16,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isZh ? '➕ 编辑模型' : '➕ Edit models',
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (!hasConfigs)
              DropdownMenuItem<ApiConfig>(
                enabled: false,
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Colors.grey.shade600,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isZh ? '未配置模型，请去设置' : 'No models, go to Settings',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          hint: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🤖', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 100),
                child: Text(
                  hasConfigs ? displayLabel : (isZh ? '未配置' : 'N/A'),
                  style: TextStyle(
                    fontSize: 11,
                    color: hasConfigs ? cs.primary : Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          onChanged: (newCfg) {
            if (newCfg != null && onModelChanged != null) {
              onModelChanged!(newCfg);
            }
          },
        ),
      ),
    );
  }
}
