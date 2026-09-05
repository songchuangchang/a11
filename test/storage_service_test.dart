import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    final file = File('lib/services/storage_service.dart');
    source = file.readAsStringSync();
  });

  group('StorageService DB version', () {
    test('DB version is 23', () {
      expect(source, contains('version: 23'));
    });
  });

  group('StorageService DB migration v19 (per-conversation thinking)', () {
    test('v19 migration adds thinking columns to conversations', () {
      expect(
        source,
        contains(
          RegExp(r"oldVersion\s*<\s*19", multiLine: true),
        ),
      );
      expect(source, contains("'reasoningEffort'"));
      expect(source, contains("'reactAutoMode'"));
      expect(source, contains("'reactMaxRounds'"));
    });

    test('thinking columns ensured at startup', () {
      expect(
        source,
        contains(
          RegExp(
            r"_ensureColumn\(.*conversations.*reasoningEffort",
            multiLine: true,
          ),
        ),
      );
    });
  });

  group('StorageService DB migration v21 (retry version snapshots)', () {
    test('v21 migration adds message_versions table', () {
      expect(source, contains("'message_versions'"));
      expect(source, contains("'retryOfId'"));
      expect(source, contains("'versionIndex'"));
      expect(source, contains("'savedAt'"));
      expect(
        source,
        contains(
          RegExp(r"oldVersion\s*<\s*21", multiLine: true),
        ),
      );
    });

    test('message_versions ensured at startup (idempotent)', () {
      expect(
        source,
        contains(
          RegExp(
            r"CREATE TABLE IF NOT EXISTS message_versions",
            multiLine: true,
          ),
        ),
      );
    });

    test('version snapshot CRUD methods exist', () {
      expect(source, contains('saveMessageVersion'));
      expect(source, contains('loadMessageVersions'));
      expect(source, contains('deleteMessageVersions'));
    });
  });

  group('StorageService DB migration v18', () {
    test('v18 migration adds biometricLockEnabled column', () {
      expect(source, contains('biometricLockEnabled'));
      expect(
        source,
        contains(
          RegExp(r"oldVersion\s*<\s*18", multiLine: true),
        ),
      );
    });
  });

  group('StorageService startup ensureColumn', () {
    test('biometricLockEnabled is ensured at startup', () {
      expect(
        source,
        contains(
          RegExp(
            r"_ensureColumn\(.*web_search_configs.*biometricLockEnabled",
            multiLine: true,
          ),
        ),
      );
    });

    test('DB init log shows v18', () {
      expect(source, contains('DB initialized'));
      expect(source, contains('v18'));
    });
  });

  group('StorageService biometric lock methods', () {
    test('getBiometricLockEnabled method exists', () {
      expect(source, contains('getBiometricLockEnabled'));
    });

    test('setBiometricLockEnabled method exists', () {
      expect(source, contains('setBiometricLockEnabled'));
    });

    test('biometricLockEnabled uses INTEGER DEFAULT 0', () {
      expect(
        source,
        contains(
          RegExp(
            r"biometricLockEnabled.*INTEGER\s+DEFAULT\s+0",
            multiLine: true,
          ),
        ),
      );
    });
  });

  group('StorageService key methods existence', () {
    test('getWebSearchConfig exists', () {
      expect(source, contains('getWebSearchConfig'));
    });

    test('saveWebSearchConfig exists', () {
      expect(source, contains('saveWebSearchConfig'));
    });

    test('getConversations exists', () {
      expect(source, contains('getConversations'));
    });

    test('getMessages exists', () {
      expect(source, contains('getMessages'));
    });

    test('_ensureColumn exists', () {
      expect(source, contains('_ensureColumn'));
    });
  });
}