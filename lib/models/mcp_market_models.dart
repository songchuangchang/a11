import 'dart:io';

/// v1.7.2 安全改进：危险工具黑名单
/// 这些工具可能执行破坏性操作，调用前需要用户确认
class McpDangerousTools {
  /// 危险工具名称黑名单（不区分大小写）
  static const Set<String> dangerousToolNames = {
    // 文件操作
    'delete_file', 'delete', 'remove_file', 'remove',
    'delete_directory', 'rmdir', 'rm',
    // 执行类
    'execute', 'exec', 'run_command', 'run', 'shell',
    'execute_command', 'system', 'eval',
    // 数据库操作
    'execute_sql', 'drop_table', 'delete_from',
    'truncate', 'drop_database',
    // 网络操作
    'send_request', 'http_request', 'fetch',
    // 危险操作
    'format', 'reset', 'clear', 'wipe',
    'send_email', 'send_message',
  };

  /// 检查工具是否危险
  static bool isDangerous(String toolName) {
    final normalized = toolName.toLowerCase().trim();
    return dangerousToolNames.contains(normalized);
  }

  /// 获取危险工具的警告信息
  static String getWarning(String toolName, {bool isZh = true}) {
    if (isZh) {
      return '⚠️ 危险操作：此工具可能执行破坏性操作（删除文件、执行命令、修改数据库等）。\n\n工具：$toolName\n\n请确认你了解此操作的风险。';
    }
    return '⚠️ Dangerous Operation: This tool may perform destructive actions (delete files, execute commands, modify databases, etc.).\n\nTool: $toolName\n\nPlease confirm you understand the risks.';
  }
}

class McpModelFormatException implements FormatException {
  @override
  final String message;
  @override
  final dynamic source;
  @override
  final int? offset;

  const McpModelFormatException(this.message, [this.source, this.offset]);

  @override
  String toString() => 'McpModelFormatException: $message';
}

class McpRegistryServer {
  static const int maxNameLength = 200;
  static const int maxTitleLength = 200;
  static const int maxDescriptionLength = 4000;
  static const int maxVersionLength = 100;

  final String name;
  final String title;
  final String description;
  final String version;
  final String status;
  final Uri? homepage;
  final Uri endpoint;
  final String transportType;

  const McpRegistryServer({
    required this.name,
    required this.title,
    required this.description,
    required this.version,
    required this.status,
    required this.endpoint,
    required this.transportType,
    this.homepage,
  });

  factory McpRegistryServer.fromJson(Map<String, dynamic> json) {
    final rawServer = json['server'];
    final server =
        rawServer is Map ? Map<String, dynamic>.from(rawServer) : json;
    final name = _requiredString(server, 'name', maxNameLength);
    final version = _requiredString(server, 'version', maxVersionLength);
    final title = _optionalString(server, 'title', maxTitleLength) ?? name;
    final description =
        _optionalString(server, 'description', maxDescriptionLength) ?? '';

    final officialMeta = _officialMetadata(json);
    final status =
        (_optionalString(officialMeta, 'status', 40) ?? 'active').toLowerCase();
    final remote = _selectRemote(server['remotes']);
    final endpoint = Uri.tryParse(remote.$2);
    if (!isSafeMcpHttpsUri(endpoint)) {
      throw const McpModelFormatException('Remote endpoint must be HTTPS');
    }

    Uri? homepage;
    final homepageValue = _optionalString(server, 'websiteUrl', 2048) ??
        _optionalString(server, 'homepage', 2048);
    if (homepageValue != null) {
      final parsed = Uri.tryParse(homepageValue);
      if (parsed != null &&
          parsed.scheme == 'https' &&
          parsed.host.isNotEmpty) {
        homepage = parsed;
      }
    }

    return McpRegistryServer(
      name: name,
      title: title,
      description: description,
      version: version,
      status: status,
      homepage: homepage,
      endpoint: endpoint!,
      transportType: remote.$1,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'title': title,
        'description': description,
        'version': version,
        'status': status,
        'homepage': homepage?.toString(),
        'endpoint': endpoint.toString(),
        'transportType': transportType,
      };

  factory McpRegistryServer.fromCacheJson(Map<String, dynamic> json) {
    final endpoint = Uri.tryParse(json['endpoint'] as String? ?? '');
    if (!isSafeMcpHttpsUri(endpoint)) {
      throw const McpModelFormatException('Cached endpoint is invalid');
    }
    final homepageValue = json['homepage'] as String?;
    final parsedHomepage =
        homepageValue == null ? null : Uri.tryParse(homepageValue);
    return McpRegistryServer(
      name: _requiredString(json, 'name', maxNameLength),
      title: _requiredString(json, 'title', maxTitleLength),
      description:
          _optionalString(json, 'description', maxDescriptionLength) ?? '',
      version: _requiredString(json, 'version', maxVersionLength),
      status: _requiredString(json, 'status', 40),
      endpoint: endpoint!,
      transportType: _requiredString(json, 'transportType', 40),
      homepage: parsedHomepage,
    );
  }

  static Map<String, dynamic> _officialMetadata(Map<String, dynamic> json) {
    final rawMeta = json['_meta'];
    if (rawMeta is! Map) return const {};
    final official = rawMeta['io.modelcontextprotocol.registry/official'];
    return official is Map ? Map<String, dynamic>.from(official) : const {};
  }

  static (String, String) _selectRemote(dynamic rawRemotes) {
    if (rawRemotes is! List) {
      throw const McpModelFormatException('Server has no remote transport');
    }
    String? sseUrl;
    for (final raw in rawRemotes) {
      if (raw is! Map) continue;
      final remote = Map<String, dynamic>.from(raw);
      final type = remote['type'];
      final url = remote['url'];
      if (url is! String || url.trim().isEmpty) continue;
      final parsed = Uri.tryParse(url);
      if (!isSafeMcpHttpsUri(parsed)) continue;
      if (type == 'streamable-http') {
        return ('streamable-http', url);
      }
      if (type == 'sse' && sseUrl == null) {
        sseUrl = url;
      }
    }
    if (sseUrl != null) return ('sse', sseUrl);
    throw const McpModelFormatException(
        'Server has no supported remote transport');
  }
}

class McpToolDefinition {
  static const int maxNameLength = 128;
  static const int maxDescriptionLength = 2000;
  static const int maxToolCount = 100;

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const McpToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  factory McpToolDefinition.fromJson(Map<String, dynamic> json) {
    final name = _requiredString(json, 'name', maxNameLength);
    if (!RegExp(r'^[A-Za-z0-9_.:/-]+$').hasMatch(name)) {
      throw const McpModelFormatException(
          'Tool name contains invalid characters');
    }
    final rawSchema = json['inputSchema'];
    if (rawSchema is! Map) {
      throw const McpModelFormatException('Tool inputSchema must be an object');
    }
    final schema = Map<String, dynamic>.from(rawSchema);
    _validateJsonValue(schema, depth: 0, maxDepth: 12, itemBudget: 1000);
    return McpToolDefinition(
      name: name,
      description:
          _optionalString(json, 'description', maxDescriptionLength) ?? '',
      inputSchema: schema,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

class InstalledMcpConfig {
  final String serverName;
  final String serverVersion;
  final Uri endpoint;
  final String protocolVersion;
  final List<McpToolDefinition> tools;
  final DateTime lastVerifiedAt;

  const InstalledMcpConfig({
    required this.serverName,
    required this.serverVersion,
    required this.endpoint,
    required this.protocolVersion,
    required this.tools,
    required this.lastVerifiedAt,
  });

  factory InstalledMcpConfig.fromJson(Map<String, dynamic> json) {
    final endpoint = Uri.tryParse(json['endpoint'] as String? ?? '');
    final verifiedAt =
        DateTime.tryParse(json['lastVerifiedAt'] as String? ?? '');
    final rawTools = json['tools'];
    if (!isSafeMcpHttpsUri(endpoint) || rawTools is! List) {
      throw const McpModelFormatException('Installed endpoint is invalid');
    }
    if (verifiedAt == null ||
        rawTools.length > McpToolDefinition.maxToolCount) {
      throw const McpModelFormatException(
          'Installed MCP configuration is invalid');
    }
    return InstalledMcpConfig(
      serverName: _requiredString(json, 'serverName', 200),
      serverVersion: _requiredString(json, 'serverVersion', 100),
      endpoint: endpoint!,
      protocolVersion: _requiredString(json, 'protocolVersion', 40),
      tools: rawTools.map((e) {
        if (e is! Map) {
          throw const McpModelFormatException('Installed MCP tool is invalid');
        }
        return McpToolDefinition.fromJson(Map<String, dynamic>.from(e));
      }).toList(growable: false),
      lastVerifiedAt: verifiedAt.toUtc(),
    );
  }

  Map<String, dynamic> toJson() => {
        'serverName': serverName,
        'serverVersion': serverVersion,
        'endpoint': endpoint.toString(),
        'protocolVersion': protocolVersion,
        'tools': tools.map((e) => e.toJson()).toList(growable: false),
        'lastVerifiedAt': lastVerifiedAt.toUtc().toIso8601String(),
      };
}

class McpRegistryPage {
  final List<McpRegistryServer> servers;
  final String? nextCursor;
  final bool fromCache;
  final DateTime? cachedAt;

  const McpRegistryPage({
    required this.servers,
    this.nextCursor,
    this.fromCache = false,
    this.cachedAt,
  });

  McpRegistryPage copyWith({
    List<McpRegistryServer>? servers,
    String? nextCursor,
    bool? fromCache,
    DateTime? cachedAt,
  }) =>
      McpRegistryPage(
        servers: servers ?? this.servers,
        nextCursor: nextCursor ?? this.nextCursor,
        fromCache: fromCache ?? this.fromCache,
        cachedAt: cachedAt ?? this.cachedAt,
      );
}

bool isSafeMcpHttpsUri(Uri? uri) {
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    return false;
  }
  final address = InternetAddress.tryParse(host);
  if (address == null) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    final a = bytes[0];
    final b = bytes[1];
    return a != 0 &&
        a != 10 &&
        a != 127 &&
        !(a == 100 && b >= 64 && b <= 127) &&
        !(a == 169 && b == 254) &&
        !(a == 172 && b >= 16 && b <= 31) &&
        !(a == 192 && (b == 0 || b == 168)) &&
        !(a == 198 && (b == 18 || b == 19)) &&
        a < 224;
  }
  // M-2 修复：拦截 IPv4-mapped IPv6（如 ::ffff:127.0.0.1、::ffff:10.0.0.1）。
  // 前 10 字节为 0、第 10/11 字节为 0xffff 时，后 4 字节是内嵌 IPv4，需按私网/环回规则判定。
  if (bytes.length == 16 &&
      bytes.take(10).every((value) => value == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff) {
    final a = bytes[12];
    final b = bytes[13];
    return !(a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && (b == 0 || b == 168)) ||
        (a == 198 && (b == 18 || b == 19)) ||
        a >= 224);
  }
  if (bytes.every((value) => value == 0) ||
      (bytes.take(15).every((value) => value == 0) && bytes[15] == 1) ||
      (bytes[0] & 0xfe) == 0xfc ||
      (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) ||
      bytes[0] == 0xff) {
    return false;
  }
  return true;
}

String _requiredString(Map<String, dynamic> json, String key, int maxLength) {
  final value = _optionalString(json, key, maxLength);
  if (value == null || value.isEmpty) {
    throw McpModelFormatException('$key is required');
  }
  return value;
}

String? _optionalString(Map<String, dynamic> json, String key, int maxLength) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.length > maxLength) {
    throw McpModelFormatException('$key is invalid');
  }
  return value.trim();
}

int _validateJsonValue(
  dynamic value, {
  required int depth,
  required int maxDepth,
  required int itemBudget,
}) {
  if (depth > maxDepth || itemBudget < 0) {
    throw const McpModelFormatException('JSON structure exceeds limits');
  }
  var remaining = itemBudget - 1;
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String || (entry.key as String).length > 256) {
        throw const McpModelFormatException('JSON object key is invalid');
      }
      remaining = _validateJsonValue(
        entry.value,
        depth: depth + 1,
        maxDepth: maxDepth,
        itemBudget: remaining,
      );
    }
  } else if (value is List) {
    for (final item in value) {
      remaining = _validateJsonValue(
        item,
        depth: depth + 1,
        maxDepth: maxDepth,
        itemBudget: remaining,
      );
    }
  } else if (value is! String &&
      value is! num &&
      value is! bool &&
      value != null) {
    throw const McpModelFormatException('Unsupported JSON value');
  } else if (value is String && value.length > 10000) {
    throw const McpModelFormatException('JSON string exceeds limit');
  }
  return remaining;
}
