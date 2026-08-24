import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aichat/services/mcp_registry_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('parses, filters, deduplicates, and searches safe registry entries',
      () async {
    final client = MockClient((request) async => http.Response(
          jsonEncode(
            {
              'metadata': {'nextCursor': 'next-1'},
              'servers': [
                _entry('safe.one', 'Safe One', 'https://api.example.com/mcp'),
                _entry(
                    'safe.one', 'Duplicate', 'https://api.example.com/other'),
                _entry('private', 'Private', 'https://localhost/mcp'),
                _entry('credentialed', 'Credentialed',
                    'https://secure.example.com/mcp',
                    credential: true),
                {
                  'server': {'name': 'broken'}
                },
                _entry('deleted', 'Deleted', 'https://deleted.example.com/mcp',
                    status: 'deleted'),
              ],
            },
          ),
          200,
          headers: {'content-type': 'application/json'},
        ));
    final service = McpRegistryService(
        client: client, preferences: SharedPreferences.getInstance);

    final page = await service.fetchPage(search: 'safe');
    expect(page.servers.map((e) => e.name), ['safe.one']);
    expect(page.nextCursor, 'next-1');
    expect(page.fromCache, isFalse);
  });

  test('uses bounded cache fallback and applies search to cached data',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final client = MockClient((_) async => http.Response('offline', 503));
    final service = McpRegistryService(
        client: client, preferences: SharedPreferences.getInstance);

    await prefs.setString(
        'mcp_registry_first_page_v1',
        jsonEncode({
          'cachedAt': DateTime.now().toUtc().toIso8601String(),
          'servers': [
            {
              'name': 'cached.one',
              'title': 'Cached One',
              'description': 'usable',
              'version': '1',
              'status': 'active',
              'endpoint': 'https://cache.example.com/mcp',
              'transportType': 'streamable-http',
            },
          ],
        }));

    final page = await service.fetchPage(search: 'cached');
    expect(page.fromCache, isTrue);
    expect(page.servers.single.name, 'cached.one');

    await prefs.setString('mcp_registry_first_page_v1', '{bad json');
    await expectLater(
        service.fetchPage(), throwsA(isA<McpRegistryException>()));
  });

  test('rejects invalid limits, cursors, content type, and redirects',
      () async {
    final service = McpRegistryService(
      client: MockClient((_) async => http.Response('', 302,
          headers: {'location': 'https://other.example.com'})),
      preferences: SharedPreferences.getInstance,
    );
    expect(() => service.fetchPage(limit: 0),
        throwsA(isA<McpRegistryException>()));
    expect(() => service.fetchPage(cursor: ''),
        throwsA(isA<McpRegistryException>()));
    await expectLater(service.fetchPage(allowCacheFallback: false),
        throwsA(isA<McpRegistryException>()));
  });
}

Map<String, dynamic> _entry(String name, String title, String url,
        {String status = 'active', bool credential = false}) =>
    {
      'server': {
        'name': name,
        'title': title,
        'description': 'description',
        'version': '1.0.0',
        if (credential) 'authorization': {'required': true},
        'remotes': [
          {'type': 'streamable-http', 'url': url},
        ],
      },
      '_meta': {
        'io.modelcontextprotocol.registry/official': {'status': status},
      },
    };
