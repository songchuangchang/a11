// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

/// Schema 完整性自检
///
/// 扫描 storage_service.dart 的 CREATE TABLE 语句，确保：
///   1. conversations 包含 contextAuto / autoCompress 列
///   2. messages 包含 attachments 列
///   3. web_search_configs 包含 serpApiKey / braveApiKey / googleCseApiKey 列
///
/// 这能在 CI / 本地 flutter test 阶段就抓出"schema 双向漏写"问题，
/// 避免 bug 要用户跑到 onCreate 路径才发现（v1.4.2 踩坑 #43）。
void main() {
  late String source;

  setUpAll(() {
    final file = File('lib/services/storage_service.dart');
    source = file.readAsStringSync();
  });

  group('Schema integrity - _createV1Tables CREATE TABLE', () {
    test('conversations 表存在', () {
      expect(source, contains('CREATE TABLE conversations'));
    });

    test('conversations 含 contextAuto（v1.4.2 修复项）', () {
      expect(source, contains(RegExp(r'contextAuto\s+INTEGER')));
    });

    test('conversations 含 autoCompress（v1.4.2 修复项）', () {
      expect(source, contains(RegExp(r'autoCompress\s+INTEGER')));
    });

    test('conversations 含 enable20sCheck', () {
      expect(source, contains(RegExp(r'enable20sCheck\s+INTEGER')));
    });

    test('messages 表存在', () {
      expect(source, contains('CREATE TABLE messages'));
    });

    test('messages 含 attachments 列', () {
      expect(source, contains(RegExp(r'attachments\s+TEXT')));
    });
  });

  group('Schema integrity - web_search_configs 列', () {
    test('web_search_configs 含 tavilyApiKey', () {
      expect(source, contains('tavilyApiKey'));
    });

    test('web_search_configs 含 serpApiKey', () {
      expect(source, contains('serpApiKey'));
    });

    test('web_search_configs 含 braveApiKey', () {
      expect(source, contains('braveApiKey'));
    });

    test('web_search_configs 含 googleCseApiKey / googleCseId', () {
      expect(source, contains('googleCseApiKey'));
      expect(source, contains('googleCseId'));
    });
  });

  group('Schema integrity - 启动自检', () {
    test('存在 PRAGMA 自检方法 _ensureColumn', () {
      expect(source, contains('_ensureColumn'));
    });

    test('init 里调用了 _ensureColumn（conversations.contextAuto）', () {
      expect(
          source,
          contains(RegExp(
              r'_ensureColumn\(.*conversations.*contextAuto',
              multiLine: true)));
    });

    test('init 里调用了 _ensureColumn（conversations.autoCompress）', () {
      expect(
          source,
          contains(RegExp(
              r'_ensureColumn\(.*conversations.*autoCompress',
              multiLine: true)));
    });

    test('init 里调用了 _ensureColumn（messages.attachments）', () {
      expect(
          source,
          contains(RegExp(
              r'_ensureColumn\(.*messages.*attachments',
              multiLine: true)));
    });
  });
}
