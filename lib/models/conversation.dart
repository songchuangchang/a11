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
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }

  String toJson() => json.encode(toMap());

  factory Conversation.fromJson(String source) =>
      Conversation.fromMap(json.decode(source) as Map<String, dynamic>);
}
