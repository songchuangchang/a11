import 'dart:convert';
import 'package:uuid/uuid.dart';

class Conversation {
  final String id;
  String title;
  String apiConfigId;
  String? lastMessage;
  int contextLimit;
  double temperature;
  double topP;
  bool enable20sCheck;
  bool contextAuto;
  bool autoCompress;
  bool isPinned;
  // v1.7.25：思考相关改为每对话独有
  bool reactEnabled; // 自主思考总开关（原全局，改为每对话独有）
  bool reactAutoMode; // 思考程度：自动档
  int reactMaxRounds; // 思考程度：轮数/上限（自动档=上限）
  double reasoningEffort; // 思考强度：0.0=默认(跟随轮数) 0.1–1.0 连续（≤0.33 low / ≤0.66 medium / 否则 high）
  // v1.7.34：跨对话记忆 + 深度研究 + 子代理编排
  String summary; // 跨对话记忆摘要（后台 completeChat 生成，≤500 字）
  bool memoryEnabled; // 跨对话记忆总开关（关闭时发送前不注入历史摘要）
  bool deepResearchMode; // 深度研究模式（自动开启多专家混合 + 更高轮数 + 关闭 20s 自检）
  String subagentMode; // 子代理模式：auto / main_only / force_search / force_synthesis / force_plugin
  DateTime updatedAt;
  DateTime createdAt;

  Conversation({
    required this.id,
    required this.title,
    required this.apiConfigId,
    this.lastMessage,
    this.contextLimit = 20,
    this.temperature = 0.7,
    this.topP = 1.0,
    this.enable20sCheck = true,
    this.contextAuto = true,
    this.autoCompress = false,
    this.isPinned = false,
    this.reactEnabled = true,
    this.reactAutoMode = true,
    this.reactMaxRounds = 30,
    this.reasoningEffort = 0.0,
    this.summary = '',
    this.memoryEnabled = true,
    this.deepResearchMode = false,
    this.subagentMode = 'auto',
    required this.updatedAt,
    required this.createdAt,
  });

  factory Conversation.create({
    required String apiConfigId,
    String title = 'New Chat',
  }) {
    final now = DateTime.now();
    return Conversation(
      id: const Uuid().v4(),
      title: title,
      apiConfigId: apiConfigId,
      updatedAt: now,
      createdAt: now,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'apiConfigId': apiConfigId,
      'lastMessage': lastMessage,
      'contextLimit': contextLimit,
      'temperature': temperature,
      'topP': topP,
      'enable20sCheck': enable20sCheck ? 1 : 0,
      'contextAuto': contextAuto ? 1 : 0,
      'autoCompress': autoCompress ? 1 : 0,
      'isPinned': isPinned ? 1 : 0,
      'reactEnabled': reactEnabled ? 1 : 0,
      'reactAutoMode': reactAutoMode ? 1 : 0,
      'reactMaxRounds': reactMaxRounds,
      'reasoningEffort': reasoningEffort,
      'summary': summary,
      'memoryEnabled': memoryEnabled ? 1 : 0,
      'deepResearchMode': deepResearchMode ? 1 : 0,
      'subagentMode': subagentMode,
      'updatedAt': updatedAt.toIso8601String(),
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory Conversation.fromMap(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as String,
      title: map['title'] as String,
      apiConfigId: map['apiConfigId'] as String,
      lastMessage: map['lastMessage'] as String?,
      contextLimit: (map['contextLimit'] as int?) ?? 20,
      temperature: (map['temperature'] as num?)?.toDouble() ?? 0.7,
      topP: (map['topP'] as num?)?.toDouble() ?? 1.0,
      enable20sCheck: ((map['enable20sCheck'] as int?) ?? 1) == 1,
      contextAuto: ((map['contextAuto'] as int?) ?? 1) == 1,
      autoCompress: ((map['autoCompress'] as int?) ?? 0) == 1,
      isPinned: ((map['isPinned'] as int?) ?? 0) == 1,
      reactEnabled: ((map['reactEnabled'] as int?) ?? 1) == 1,
      reactAutoMode: ((map['reactAutoMode'] as int?) ?? 1) == 1,
      reactMaxRounds: (map['reactMaxRounds'] as int?) ?? 30,
      reasoningEffort: (map['reasoningEffort'] as num?)?.toDouble() ?? 0.0,
      summary: (map['summary'] as String?) ?? '',
      memoryEnabled: ((map['memoryEnabled'] as int?) ?? 1) == 1,
      deepResearchMode: ((map['deepResearchMode'] as int?) ?? 0) == 1,
      subagentMode: _sanitizeSubagentMode((map['subagentMode'] as String?) ?? 'auto'),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }

  /// 子代理模式合法值白名单——非白名单值一律回退到 'auto'（防远程 JSON 覆盖 / 手动改库引入脏数据）
  static const Set<String> kSubagentModes = {
    'auto',
    'main_only',
    'force_search',
    'force_synthesis',
    'force_plugin',
  };

  static String _sanitizeSubagentMode(String s) =>
      kSubagentModes.contains(s) ? s : 'auto';

  String toJson() => json.encode(toMap());

  factory Conversation.fromJson(String source) =>
      Conversation.fromMap(json.decode(source) as Map<String, dynamic>);
}
