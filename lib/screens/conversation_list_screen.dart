import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'dart:io';
import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../models/conversation.dart';
import '../services/storage_service.dart';
import '../services/logger_service.dart';
import 'chat_screen.dart';
import 'api_config_screen.dart';
import 'settings_screen.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({super.key});

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen> {
  List<Conversation> _conversations = [];
  List<ApiConfig> _apiConfigs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    final storage = context.read<StorageService>();
    await storage.init();
    await _loadData();
  }

  Future<void> _loadData() async {
    final storage = context.read<StorageService>();
    final convs = await storage.getConversations();
    final configs = await storage.getApiConfigs();
    if (mounted) {
      setState(() {
        _conversations = convs;
        _apiConfigs = configs;
        _isLoading = false;
      });
    }
  }

  Future<void> _createConversation() async {
    final logger = LoggerService.instance;
    logger.info('点击 新建聊天（FAB 或空态按钮）',
        cat: LogCat.ui, tag: 'conversation_list');
    try {
      final storage = context.read<StorageService>();
      if (!storage.isInitialized) {
        logger.info('Storage 未初始化，_createConversation 补 init()',
            cat: LogCat.db, tag: 'fallback');
        await storage.init();
      }
      List<ApiConfig> configs = List.from(_apiConfigs);
      if (configs.isEmpty) {
        logger.info('API configs 为空，创建默认配置',
            cat: LogCat.db, tag: 'fallback');
        final config = ApiConfig.create();
        await storage.saveApiConfig(config);
        configs = await storage.getApiConfigs();
        if (mounted) setState(() => _apiConfigs = configs);
      }
      if (configs.isEmpty) {
        throw StateError('无法创建默认 API 配置');
      }
      final conv = Conversation.create(apiConfigId: configs.first.id);
      logger.info('创建新会话 id=${conv.id} apiConfigId=${conv.apiConfigId}',
          cat: LogCat.chat, tag: 'new');
      await storage.saveConversation(conv);
      logger.info('saveConversation 成功 id=${conv.id}',
          cat: LogCat.db, tag: 'insert');
      if (mounted) await _loadData();
      if (mounted) {
        logger.nav('push → ChatScreen conv=${conv.id}');
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(conversation: conv),
          ),
        );
        if (mounted) await _loadData();
      }
    } catch (e, st) {
      logger.error(
        '_createConversation 失败: $e',
        error: e,
        stack: st,
        cat: LogCat.error,
        tag: 'conversation_list',
      );
      if (mounted) {
        final isZh =
            AppLocalizations.of(context).locale.languageCode == 'zh';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isZh
              ? '新建聊天失败：${e.runtimeType} $e'
              : 'Failed to create chat: ${e.runtimeType} $e')),
        );
      }
    }
  }

  /// v1.3.6：打开系统下载文件夹（多策略回退）
  Future<void> _openDownloadFolder() async {
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';
    String? dirPath;
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) dirPath = downloads.path;
    } catch (_) {}
    if (dirPath == null) {
      try {
        final externals = await getExternalStorageDirectories();
        if (externals != null && externals.isNotEmpty) {
          dirPath = externals.first.path;
        }
      } catch (_) {}
    }
    if (dirPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(
              isZh ? '无法获取下载目录路径' : 'Cannot get downloads directory path')),
        );
      }
      return;
    }
    // 确保目录存在
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (_) {}

    // v1.3.6：优先用 OpenFilex（内部走 ACTION_VIEW intent，对目录路径支持好）
    try {
      final r = await OpenFilex.open(dirPath);
      if (r.type == ResultType.done) return;
    } catch (_) {}

    // 回退1: url_launcher 的 SAF content:// scheme
    final uris = <Uri>[
      Uri.parse('content://com.android.externalstorage.documents/document/primary%3ADownload%2FNexus_Downloads'),
      Uri.parse('content://com.android.externalstorage.documents/document/primary%3ADownload'),
    ];
    for (final uri in uris) {
      try {
        final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (launched) return;
      } catch (_) {}
    }

    // 全部失败 → 提示路径让用户手动打开
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isZh
              ? '无法自动打开文件管理器\n下载路径：$dirPath'
              : 'Cannot open file manager automatically\nDownload path: $dirPath'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.tr('appTitle')),
        actions: [
          // v1.3.5：打开下载文件夹
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: l.locale.languageCode == 'zh' ? '下载文件夹' : 'Downloads folder',
            onPressed: _openDownloadFolder,
          ),
          IconButton(
            icon: const Icon(Icons.cloud_outlined),
            tooltip: l.tr('apiSettings'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ApiConfigScreen()),
              ).then((_) => _loadData());
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: l.tr('settings'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _conversations.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 64,
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 16),
                      Text(l.tr('noConversations'),
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _createConversation,
                        icon: const Icon(Icons.add),
                        label: Text(l.tr('newChat')),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: ListView.builder(
                    itemCount: _conversations.length,
                    itemBuilder: (context, index) {
                      final conv = _conversations[index];
                      return Dismissible(
                        key: Key(conv.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) async {
                          await context
                              .read<StorageService>()
                              .deleteConversation(conv.id);
                          _loadData();
                        },
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                Theme.of(context).colorScheme.primaryContainer,
                            child: const Icon(Icons.chat),
                          ),
                          title: Text(conv.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            conv.lastMessage ?? l.tr('noConversations'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            '${conv.updatedAt.hour}:${conv.updatedAt.minute.toString().padLeft(2, '0')}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(conversation: conv),
                              ),
                            ).then((_) => _loadData());
                          },
                        ),
                      );
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createConversation,
        child: const Icon(Icons.add),
      ),
    );
  }
}
