import 'package:flutter/material.dart';
import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../models/plugin_hint_config.dart';

/// ChatInput 状态快照（v1.7.18 需求2）
///
/// 把原 ChatInput 26 个零散构造参数中的「状态类」参数按 7 组归并为一个
/// 不可变 value object，使 ChatInput 构造函数降至 5 参数（config + actions +
/// controller + onSend + onStop）。
///
/// 纯数据、无逻辑、const 构造。所有字段带默认值，保证 chat_screen 迁移时
/// 漏传的字段退化为安全默认（不崩、不破坏现有行为）。
@immutable
class ChatInputConfig {
  // -------- 🌐 搜索组 --------
  final bool searchMode;
  final bool searchEnabled;

  // -------- 🧠 思考组 --------
  final int reactRounds;
  final String reactLevelLabel;
  final bool reactEnabled;
  final bool reactAutoMode;
  // 思考强度（每对话独有）0.0=默认 0.1–1.0 连续小数
  final double reasoningEffort;

  // -------- 🔌 插件组（v1.7.17 三态）--------
  final PluginHintMode pluginHintMode;
  final int pluginHintManualCount;

  // -------- 🤖 模型组（v1.6.0）--------
  final List<ApiConfig> availableConfigs;
  final ApiConfig? currentConfig;

  // -------- 📎 附件组（v1.3.6）--------
  final List<MessageAttachment> pendingAttachments;

  // -------- 队列 / 状态组 --------
  final int pendingFollowupCount;
  final bool isGenerating;

  const ChatInputConfig({
    this.searchMode = false,
    this.searchEnabled = true,
    this.reactRounds = 3,
    this.reactLevelLabel = '中 (Medium)',
    this.reactEnabled = true,
    this.reactAutoMode = false,
    this.reasoningEffort = 0.0,
    this.pluginHintMode = PluginHintMode.off,
    this.pluginHintManualCount = 0,
    this.availableConfigs = const <ApiConfig>[],
    this.currentConfig,
    this.pendingAttachments = const <MessageAttachment>[],
    this.pendingFollowupCount = 0,
    this.isGenerating = false,
  });
}

/// 思考强度数值 → 展示文案（与 ApiService.reasoningEffortForConversation 阈值一致）
/// 0.0=默认(自动)；≤0.33 低；≤0.66 中；否则 高，均附带一位小数数值
String reasoningEffortLabel(double v, bool isZh) {
  if (v <= 0) return isZh ? '默认（自动）' : 'Default (auto)';
  final s = v.toStringAsFixed(1);
  if (v <= 0.33) return isZh ? '低 $s' : 'Low $s';
  if (v <= 0.66) return isZh ? '中 $s' : 'Medium $s';
  return isZh ? '高 $s' : 'High $s';
}
