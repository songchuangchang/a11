import 'package:flutter/material.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';

/// ChatInput 回调集合（v1.7.18 需求2）
///
/// 把原 ChatInput 9 个可选回调归并为一个不可变 value object。
/// - [onLongPressSearch] 🌐 长按 → 跳转联网搜索设置页
/// - [onLongPressReact]  🧠 长按 → 跳转自主思考设置页
/// - [onModelChanged] 只承载真模型选中；选「➕编辑模型」由 ModelSwitcher
///   内部 Navigator.push(SettingsScreen)，不走此回调。
@immutable
class ChatInputActions {
  final VoidCallback? onToggleSearch;
  final VoidCallback? onOpenSearchSettings;
  final VoidCallback? onLongPressSearch;
  final VoidCallback? onLongPressReact;
  final ValueChanged<double>? onReasoningEffortChanged;
  final VoidCallback? onTogglePluginHint;
  final VoidCallback? onEditPluginHint;
  final ValueChanged<ApiConfig>? onModelChanged;
  final VoidCallback? onPickAttachment;
  final void Function(MessageAttachment)? onRemoveAttachment;

  const ChatInputActions({
    this.onToggleSearch,
    this.onOpenSearchSettings,
    this.onLongPressSearch,
    this.onLongPressReact,
    this.onReasoningEffortChanged,
    this.onTogglePluginHint,
    this.onEditPluginHint,
    this.onModelChanged,
    this.onPickAttachment,
    this.onRemoveAttachment,
  });
}
