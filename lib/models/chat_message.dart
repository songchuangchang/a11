import 'dart:convert';
import 'package:uuid/uuid.dart';

enum MessageRole { user, assistant, system }

extension MessageRoleExtension on MessageRole {
  String get value {
    switch (this) {
      case MessageRole.user:
        return 'user';
      case MessageRole.assistant:
        return 'assistant';
      case MessageRole.system:
        return 'system';
    }
  }

  static MessageRole fromString(String value) {
    switch (value) {
      case 'user':
        return MessageRole.user;
      case 'assistant':
        return MessageRole.assistant;
      case 'system':
        return MessageRole.system;
      default:
        return MessageRole.user;
    }
  }
}

/// v1.3.1 build 11: ReAct 协议每一步（内存级，不落库）
/// kind: 'thinking' | 'search' | 'search_result'
/// v1.7.22: 新增 phase（阶段）和 round（轮次）字段，支持思考过程分类折叠
class ReasoningStep {
  final String kind;
  String content;
  int? resultCount;
  int? latencyMs;
  final DateTime ts;
  final String phase;
  final int round;
  String? pluginId;
  String? pluginName;
  String? toolName;
  String status;
  String? arguments;
  String? resultSummary;

  ReasoningStep(this.kind, this.content, {
    this.resultCount,
    this.latencyMs,
    this.phase = '',
    this.round = 0,
    this.pluginId,
    this.pluginName,
    this.toolName,
    this.status = '',
    this.arguments,
    this.resultSummary,
  }) : ts = DateTime.now();

  ReasoningStep._({
    required this.kind,
    required this.content,
    this.resultCount,
    this.latencyMs,
    required this.ts,
    this.phase = '',
    this.round = 0,
    this.pluginId,
    this.pluginName,
    this.toolName,
    this.status = '',
    this.arguments,
    this.resultSummary,
  });

  Map<String, dynamic> toMap() => {
        'kind': kind,
        'content': content,
        if (resultCount != null) 'resultCount': resultCount,
        if (latencyMs != null) 'latencyMs': latencyMs,
        'ts': ts.toIso8601String(),
        if (phase.isNotEmpty) 'phase': phase,
        if (round > 0) 'round': round,
        if (pluginId != null) 'pluginId': pluginId,
        if (pluginName != null) 'pluginName': pluginName,
        if (toolName != null) 'toolName': toolName,
        if (status.isNotEmpty) 'status': status,
        if (arguments != null) 'arguments': arguments,
        if (resultSummary != null) 'resultSummary': resultSummary,
      };

  factory ReasoningStep.fromMap(Map<String, dynamic> m) => ReasoningStep._(
        kind: m['kind'] as String,
        content: m['content'] as String,
        resultCount: m['resultCount'] as int?,
        latencyMs: m['latencyMs'] as int?,
        ts: DateTime.parse(m['ts'] as String),
        phase: (m['phase'] as String?) ?? '',
        round: (m['round'] as int?) ?? 0,
        pluginId: m['pluginId'] as String?,
        pluginName: m['pluginName'] as String?,
        toolName: m['toolName'] as String?,
        status: (m['status'] as String?) ?? '',
        arguments: m['arguments'] as String?,
        resultSummary: m['resultSummary'] as String?,
      );
}

/// v1.7.26 (E3)：重试版本快照（v1.7.22 原为 UI 层内存结构，现下沉到 models
/// 供 StorageService 持久化到 message_versions 表——此前仅存活于进程内存，
/// 重启后版本切换功能丢失）
class RetryVersion {
  final String content;
  final List<ReasoningStep> reasoningSteps;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int injectedWebSearchCount;
  final bool showStaleFootnote;
  final String modelName;
  RetryVersion({
    required this.content,
    this.reasoningSteps = const [],
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.injectedWebSearchCount = 0,
    this.showStaleFootnote = false,
    this.modelName = '',
  });
}

/// v1.3.6：📎 附件类型
/// - text: txt/md 等纯文本（extractedText 直接读文件内容）
/// - image: 照片（localPath 存本地路径，发 API 时再转 base64，避免 DB 存大块 base64）
/// - doc: pdf/docx（extractedText 存已抽取的文本）
enum AttachmentType { text, image, doc }

extension AttachmentTypeExtension on AttachmentType {
  String get value {
    switch (this) {
      case AttachmentType.text:
        return 'text';
      case AttachmentType.image:
        return 'image';
      case AttachmentType.doc:
        return 'doc';
    }
  }

  static AttachmentType fromString(String v) {
    switch (v) {
      case 'image':
        return AttachmentType.image;
      case 'doc':
        return AttachmentType.doc;
      default:
        return AttachmentType.text;
    }
  }
}

class MessageAttachment {
  final String id;
  final AttachmentType type;
  final String fileName;
  final String? extractedText; // text/doc: 已抽取文本（过长会截断）
  final String? localPath; // image: 本地路径（发 API 时再转 base64）
  final String? mimeType; // image: image/jpeg 等
  final int? sizeBytes;

  const MessageAttachment({
    required this.id,
    required this.type,
    required this.fileName,
    this.extractedText,
    this.localPath,
    this.mimeType,
    this.sizeBytes,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type.value,
        'fileName': fileName,
        if (extractedText != null) 'extractedText': extractedText,
        if (localPath != null) 'localPath': localPath,
        if (mimeType != null) 'mimeType': mimeType,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
      };

  factory MessageAttachment.fromMap(Map<String, dynamic> m) =>
      MessageAttachment(
        id: m['id'] as String,
        type: AttachmentTypeExtension.fromString(m['type'] as String),
        fileName: m['fileName'] as String,
        extractedText: m['extractedText'] as String?,
        localPath: m['localPath'] as String?,
        mimeType: m['mimeType'] as String?,
        sizeBytes: m['sizeBytes'] as int?,
      );
}

class ChatMessage {
  final String id;
  final String conversationId;
  final MessageRole role;
  String content;
  /// v1.7.26 (E4)：改为可变——历史消息重试后需写回旧对话原有的时间戳做原位
  /// 重插，DB 依赖 createdAt ASC 排序，若沿用新时间则重载后顺序会被打乱
  DateTime createdAt;
  String? modelName;

  // ===== UI 标记（不落库 / 不参与序列化，纯用于本次会话内气泡展示）=====
  /// true → 在气泡底部加一行"⚠️ 基于 AI 内置知识，可能已过时"的淡色 footnote
  bool showStaleFootnote = false;
  /// true → 在气泡底部加一行"🌐 已联网搜索注入 N 条搜索结果"的淡色 footnote
  int injectedWebSearchCount = 0;
  /// v1.3.1 build 11: ReAct 思考过程（每一步 thinking/search/结果）
  final List<ReasoningStep> reasoningSteps = [];
  /// true → ReAct 循环已经跑过（决定 UI 上显示折叠面板）
  bool get hasReasoning {
    // v1.7.25：只认"有真实内容"的思考——纯进度占位（🧠 思考中…/📦/📩）不算，
    // 单步骤流程（如纯下载）不展示无意义的思考面板；多步骤/真实思考/搜索结果才显示。
    if (reasoningSteps.isEmpty) return false;
    for (final s in reasoningSteps) {
      if (s.kind != 'thinking') return true; // search/search_result/工具结果
      final c = s.content.trim();
      if (c.isEmpty) continue;
      if (c.contains('思考中') || c.contains('Thinking') ||
          c.contains('thinking') || c.contains('📦') ||
          c.contains('📩') || c.contains('🧠')) {
        continue; // 纯进度占位
      }
      return true; // 有真实思考文本
    }
    return false;
  }
  /// v1.3.6：token 用量统计（prompt + completion + total）
  int? promptTokens;
  int? completionTokens;
  int? totalTokens;
  /// v1.3.6：📎 附件列表（落库为 JSON 字符串）
  final List<MessageAttachment> attachments = [];
  String retryOf = '';
  int retryIndex = 0;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.modelName,
    this.showStaleFootnote = false,
    this.injectedWebSearchCount = 0,
    this.retryOf = '',
    this.retryIndex = 0,
  });

  factory ChatMessage.create({
    required String conversationId,
    required MessageRole role,
    required String content,
    String? modelName,
    bool showStaleFootnote = false,
    int injectedWebSearchCount = 0,
  }) {
    return ChatMessage(
      id: const Uuid().v4(),
      conversationId: conversationId,
      role: role,
      content: content,
      createdAt: DateTime.now(),
      modelName: modelName,
      showStaleFootnote: showStaleFootnote,
      injectedWebSearchCount: injectedWebSearchCount,
    );
  }

  // 添加一步思考过程（setState 后气泡会实时刷新）
  void addReasoning(ReasoningStep step) {
    reasoningSteps.add(step);
  }
  void appendLastThinking(String chunk) {
    if (reasoningSteps.isEmpty || reasoningSteps.last.kind != 'thinking') {
      reasoningSteps.add(ReasoningStep('thinking', chunk));
    } else {
      reasoningSteps.last.content += chunk;
    }
  }
  /// v1.7.25：每轮思考强制新建独立 step。
  /// 修复：连续多轮 thinking（无 search 打断）时 appendLastThinking 会合并到
  /// 同一个 step，且 setLastReasoningPhase 把 phase 覆盖成最新轮次 → 第一轮
  /// 内容在最后"突然切换/消失"。每轮开始调用本方法即可按轮次分隔。
  void startNewThinking(String chunk) {
    reasoningSteps.add(ReasoningStep('thinking', chunk));
  }
  void markLastSearchResult({required int count, int? latencyMs, required String summary}) {
    reasoningSteps.add(ReasoningStep(
      'search_result',
      summary,
      resultCount: count,
      latencyMs: latencyMs,
    ));
  }

  void setLastReasoningPhase(String phase, int round) {
    if (reasoningSteps.isEmpty) return;
    final last = reasoningSteps.last;
    reasoningSteps[reasoningSteps.length - 1] = ReasoningStep(
      last.kind, last.content,
      resultCount: last.resultCount,
      latencyMs: last.latencyMs,
      phase: phase,
      round: round,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversationId': conversationId,
      'role': role.value,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
      'modelName': modelName,
      // v1.3.6：附件序列化为 JSON 数组字符串
      'attachments': json
          .encode(attachments.map((a) => a.toMap()).toList()),
      'retryOf': retryOf,
      'retryIndex': retryIndex,
      'reasoningSteps': json.encode(
          reasoningSteps.map((s) => s.toMap()).toList()),
      // v1.7.26 (C2)：token 用量持久化（此前仅内存，重启后丢失）
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (totalTokens != null) 'totalTokens': totalTokens,
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    final msg = ChatMessage(
      id: map['id'] as String,
      conversationId: map['conversationId'] as String,
      role: MessageRoleExtension.fromString(map['role'] as String),
      content: map['content'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
      modelName: map['modelName'] as String?,
      retryOf: (map['retryOf'] as String?) ?? '',
      retryIndex: (map['retryIndex'] as int?) ?? 0,
    );
    // v1.3.6：反序列化附件（旧消息无此列 → 空）
    final raw = map['attachments'] as String?;
    if (raw != null && raw.isNotEmpty && raw != '[]') {
      try {
        final list = json.decode(raw) as List;
        for (final item in list) {
          msg.attachments
              .add(MessageAttachment.fromMap(item as Map<String, dynamic>));
        }
      } catch (_) {
        // 容错：损坏的 JSON 当作无附件
      }
    }
    // 反序列化思考步骤
    final reasoningRaw = map['reasoningSteps'] as String?;
    if (reasoningRaw != null && reasoningRaw.isNotEmpty && reasoningRaw != '[]') {
      try {
        final list = json.decode(reasoningRaw) as List;
        for (final item in list) {
          msg.reasoningSteps
              .add(ReasoningStep.fromMap(item as Map<String, dynamic>));
        }
      } catch (_) {}
    }
    // v1.7.26 (C2)：token 用量反序列化（旧库无此列 → null）
    msg.promptTokens = map['promptTokens'] as int?;
    msg.completionTokens = map['completionTokens'] as int?;
    msg.totalTokens = map['totalTokens'] as int?;
    return msg;
  }

  String toJson() => json.encode(toMap());

  factory ChatMessage.fromJson(String source) =>
      ChatMessage.fromMap(json.decode(source) as Map<String, dynamic>);
}
