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
class ReasoningStep {
  final String kind;
  /// thinking = 思考文本 / search = query / search_result = 摘要
  String content;
  final int? resultCount;   // search_result: 返回结果数
  final int? latencyMs;     // search_result: 耗时 ms
  final DateTime ts;
  ReasoningStep(this.kind, this.content, {this.resultCount, this.latencyMs})
      : ts = DateTime.now();
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
  final DateTime createdAt;

  // ===== UI 标记（不落库 / 不参与序列化，纯用于本次会话内气泡展示）=====
  /// true → 在气泡底部加一行"⚠️ 基于 AI 内置知识，可能已过时"的淡色 footnote
  bool showStaleFootnote = false;
  /// true → 在气泡底部加一行"🌐 已联网搜索注入 N 条搜索结果"的淡色 footnote
  int injectedWebSearchCount = 0;
  /// v1.3.1 build 11: ReAct 思考过程（每一步 thinking/search/结果）
  final List<ReasoningStep> reasoningSteps = [];
  /// true → ReAct 循环已经跑过（决定 UI 上显示折叠面板）
  bool get hasReasoning => reasoningSteps.isNotEmpty;
  /// v1.3.6：token 用量统计（prompt + completion + total）
  int? promptTokens;
  int? completionTokens;
  int? totalTokens;
  /// v1.3.6：📎 附件列表（落库为 JSON 字符串）
  final List<MessageAttachment> attachments = [];

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.showStaleFootnote = false,
    this.injectedWebSearchCount = 0,
  });

  factory ChatMessage.create({
    required String conversationId,
    required MessageRole role,
    required String content,
    bool showStaleFootnote = false,
    int injectedWebSearchCount = 0,
  }) {
    return ChatMessage(
      id: const Uuid().v4(),
      conversationId: conversationId,
      role: role,
      content: content,
      createdAt: DateTime.now(),
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
  void markLastSearchResult({required int count, int? latencyMs, required String summary}) {
    reasoningSteps.add(ReasoningStep(
      'search_result',
      summary,
      resultCount: count,
      latencyMs: latencyMs,
    ));
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversationId': conversationId,
      'role': role.value,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
      // v1.3.6：附件序列化为 JSON 数组字符串
      'attachments': json
          .encode(attachments.map((a) => a.toMap()).toList()),
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    final msg = ChatMessage(
      id: map['id'] as String,
      conversationId: map['conversationId'] as String,
      role: MessageRoleExtension.fromString(map['role'] as String),
      content: map['content'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
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
    return msg;
  }

  String toJson() => json.encode(toMap());

  factory ChatMessage.fromJson(String source) =>
      ChatMessage.fromMap(json.decode(source) as Map<String, dynamic>);
}
