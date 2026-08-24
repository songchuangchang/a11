import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants.dart';
import '../models/mcp_market_models.dart';

class McpClientService {
  static const int maxRedirects = 5;
  static const int maxResponseBytes = 1024 * 1024;
  static const int maxTools = McpToolDefinition.maxToolCount;

  final http.Client _client;
  int _nextId = 0;
  String? _sessionId;
  String? _endpoint;
  Map<String, McpToolDefinition> _tools = const {};

  McpClientService({http.Client? client}) : _client = client ?? http.Client();

  Uri validateEndpointForTesting(String endpoint) =>
      _validateEndpoint(endpoint);

  Uri _validateEndpoint(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (!isSafeMcpHttpsUri(uri)) {
      throw const FormatException('MCP endpoint must be a public HTTPS URL');
    }
    return uri!;
  }

  Future<http.Response> _post(Map<String, dynamic> payload) async {
    var uri = _validateEndpoint(_endpoint!);
    for (var redirect = 0;; redirect++) {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll(_headers())
        ..body = jsonEncode(payload);
      final streamed = await _client.send(request).timeout(
            const Duration(seconds: 30),
          );
      if (!_isRedirectStatus(streamed.statusCode)) {
        return http.Response.fromStream(streamed);
      }
      if (redirect >= maxRedirects) {
        throw const FormatException('MCP redirect limit exceeded');
      }
      final location = streamed.headers['location'];
      if (location == null) {
        throw const FormatException('MCP redirect has no location');
      }
      uri = _validateEndpoint(uri.resolve(location).toString());
    }
  }

  static bool _isRedirectStatus(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'MCP-Protocol-Version': '2025-03-26',
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
      };

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    final response = await _post({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('MCP HTTP ${response.statusCode}');
    }
  }

  Future<Map<String, dynamic>> _request(
      String method, Map<String, dynamic> params) async {
    final id = ++_nextId;
    final response = await _post({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('MCP HTTP ${response.statusCode}');
    }
    final session = response.headers['mcp-session-id'];
    if (session != null && session.isNotEmpty) _sessionId = session;
    if (response.bodyBytes.length > maxResponseBytes) {
      throw Exception('MCP response is too large');
    }
    final jsonBody =
        _decodeResponse(response.body, response.headers['content-type'] ?? '');
    if (jsonBody['id'] != id) {
      throw Exception('MCP response id mismatch');
    }
    if (jsonBody['error'] is Map) {
      throw Exception(
          jsonBody['error']['message']?.toString() ?? 'MCP request failed');
    }
    final result = jsonBody['result'];
    if (result is! Map) {
      throw const FormatException('MCP result must be an object');
    }
    return Map<String, dynamic>.from(result);
  }

  Map<String, dynamic> _decodeResponse(String body, String contentType) {
    if (contentType.toLowerCase().contains('text/event-stream')) {
      final events = <String>[];
      final dataLines = <String>[];
      for (final line in body.split(RegExp(r'\r?\n'))) {
        if (line.isEmpty) {
          if (dataLines.isNotEmpty) {
            events.add(dataLines.join('\n'));
            dataLines.clear();
          }
        } else if (line.startsWith('data:')) {
          dataLines.add(line.substring(5).trimLeft());
        }
      }
      if (dataLines.isNotEmpty) events.add(dataLines.join('\n'));

      for (final data in events.reversed) {
        if (data.isNotEmpty && data != '[DONE]') {
          final decoded = jsonDecode(data);
          if (decoded is Map) return Map<String, dynamic>.from(decoded);
        }
      }
      throw const FormatException('MCP SSE response has no data');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('MCP response must be an object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<List<Map<String, dynamic>>> discoverTools(String endpoint) async {
    _endpoint = _validateEndpoint(endpoint).toString();
    _sessionId = null;
    _tools = const {};
    await _request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'Nexus', 'version': kAppVersionConst},
    });
    await _notify('notifications/initialized', {});

    final tools = <Map<String, dynamic>>[];
    final cursors = <String>{};
    String? cursor;
    do {
      final result = await _request('tools/list', {
        if (cursor != null) 'cursor': cursor,
      });
      final raw = result['tools'];
      if (raw is! List || tools.length + raw.length > maxTools) {
        throw const FormatException('MCP tools/list returned invalid tools');
      }
      for (final rawTool in raw) {
        if (rawTool is! Map) {
          throw const FormatException('MCP tool must be an object');
        }
        final tool = Map<String, dynamic>.from(rawTool);
        final definition = McpToolDefinition.fromJson(tool);
        if (_tools.containsKey(definition.name)) {
          throw const FormatException('MCP tools/list returned duplicate tool');
        }
        _tools = {..._tools, definition.name: definition};
        tools.add(tool);
      }
      final next = result['nextCursor'];
      if (next == null) {
        cursor = null;
      } else if (next is! String ||
          next.isEmpty ||
          next.length > 500 ||
          !cursors.add(next)) {
        throw const FormatException('MCP tools/list returned invalid cursor');
      } else {
        cursor = next;
      }
    } while (cursor != null);
    if (tools.isEmpty) {
      throw const FormatException('MCP tools/list returned no tools');
    }
    return tools;
  }

  /// 运行时执行 tools/call 前确保已完成 initialize 握手。
  /// 安装阶段的 discoverTools 会建立 session，但运行时恢复出的插件持有全新 client，
  /// 必须补一次 initialize + notifications/initialized，严格有状态服务端才会接受调用。
  Future<void> _ensureInitialized() async {
    if (_sessionId != null) return;
    await _request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'Nexus', 'version': kAppVersionConst},
    });
    await _notify('notifications/initialized', {});
  }

  Future<dynamic> toolsCall(
      String endpoint, String tool, Map<String, dynamic> arguments) async {
    _endpoint = _validateEndpoint(endpoint).toString();
    await _ensureInitialized();
    if (!RegExp(r'^[A-Za-z0-9_.:/-]{1,128}$').hasMatch(tool) ||
        (_tools.isNotEmpty && !_tools.containsKey(tool))) {
      throw const FormatException('MCP tool is not in the discovered schema');
    }
    if (jsonEncode(arguments).length > 100000) {
      throw const FormatException('MCP arguments exceed size limit');
    }
    final result = await _request('tools/call', {
      'name': tool,
      'arguments': arguments,
    });
    return result['content'] ?? result['structuredContent'] ?? result;
  }

  Future<void> closeSession() async {
    if (_endpoint == null || _sessionId == null) return;
    final uri = _validateEndpoint(_endpoint!);
    final request = http.Request('DELETE', uri)
      ..followRedirects = false
      ..headers.addAll(_headers());
    try {
      await _client.send(request).timeout(const Duration(seconds: 10));
    } on Exception {
      // Session closure is best effort.
    } finally {
      _sessionId = null;
    }
  }

  void close() => _client.close();
}
