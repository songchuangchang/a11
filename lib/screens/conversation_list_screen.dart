import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'dart:io';
import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../models/conversation.dart';
import '../services/biometric_service.dart';
import '../services/storage_service.dart';
import '../services/logger_service.dart';
import 'chat_screen.dart';
import '../widgets/quick_access_drawer.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({super.key});

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen> {
  List<Conversation> _conversations = [];
  List<ApiConfig> _apiConfigs = [];
  bool _isLoading = true;
  // v1.7.31：草稿缓存（conversation.id → 草稿文本）
  Map<String, String> _drafts = {};

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
    // v1.7.31：加载草稿
    final prefs = await SharedPreferences.getInstance();
    final drafts = <String, String>{};
    for (final c in convs) {
      final d = prefs.getString('chat_draft_${c.id}');
      if (d != null && d.isNotEmpty) drafts[c.id] = d;
    }
    if (mounted) {
      setState(() {
        _conversations = convs;
        _apiConfigs = configs;
        _drafts = drafts;
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

  /// v1.7.32：删除对话（带确认对话框，SlidableAction 点击触发）
  Future<void> _deleteConversation(
      BuildContext ctx, Conversation conv) async {
    final isZh =
        AppLocalizations.of(ctx).locale.languageCode == 'zh';
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(isZh ? '删除对话' : 'Delete conversation'),
        content: Text(isZh
            ? '确定要删除「${conv.title}」吗？此操作不可撤销。'
            : 'Delete "${conv.title}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(isZh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!ctx.mounted) return; // v1.7.32：await 后 context 失效保护
    await ctx.read<StorageService>().deleteConversation(conv.id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('chat_draft_${conv.id}');
    await _loadData();
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
      final r = await BiometricService.guardActivityTransition(
        () => OpenFilex.open(dirPath!),
        fallbackDuration: const Duration(seconds: 120),
      );
      if (r.type == ResultType.done) return;
    } catch (_) {}

    // 回退1: url_launcher 的 SAF content:// scheme
    final uris = <Uri>[
      Uri.parse('content://com.android.externalstorage.documents/document/primary%3ADownload%2FNexus_Downloads'),
      Uri.parse('content://com.android.externalstorage.documents/document/primary%3ADownload'),
    ];
    for (final uri in uris) {
      try {
        final launched = await BiometricService.guardActivityTransition(
          () => launchUrl(uri, mode: LaunchMode.externalApplication),
          fallbackDuration: const Duration(seconds: 120),
        );
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
    final isZh = l.locale.languageCode == 'zh';
    return Scaffold(
      // v1.7.18（需求6）：左滑快速抽屉
      // drawerEdgeDragWidth 扩大边缘识别区；drawerEnableOpenDragGesture 显式开启
      drawer: QuickAccessDrawer(isZh: isZh),
      // v1.7.32：边缘识别区从 20 加大到 60，手指从左缘右滑更容易打开抽屉
      drawerEdgeDragWidth: 60.0,
      drawerEnableOpenDragGesture: true,
      appBar: AppBar(
        // v1.7.18（需求6）：左上角汉堡图标 → 第二入口（边缘左滑为第一入口）
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: isZh ? '快速菜单' : 'Quick menu',
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Text(l.tr('appTitle')),
        // v1.7.18（决策Q1）：actions 仅留「下载文件夹」，cloud/settings 已进抽屉
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: isZh ? '下载文件夹' : 'Downloads folder',
            onPressed: _openDownloadFolder,
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
                      // v1.7.32：用 flutter_slidable 替代内置 Dismissible。
                      // 原因：Dismissible 的 onHorizontalDrag* 与 Scaffold DrawerController
                      // 边缘水平拖拽在手势竞技场互相干扰，导致右→左滑动删除经常无反应。
                      // Slidable 的 endActionPane 仅识别从右缘开始的拖拽，语义更清晰。
                      return Slidable(
                        key: Key(conv.id),
                        // 右侧（end）操作面板：右→左滑动露出红色"删除"按钮，点击弹确认框
                        endActionPane: ActionPane(
                          motion: const ScrollMotion(),
                          extentRatio: 0.25,
                          children: [
                            SlidableAction(
                              onPressed: (ctx) => _deleteConversation(ctx, conv),
                              backgroundColor:
                                  Theme.of(context).colorScheme.error,
                              foregroundColor:
                                  Theme.of(context).colorScheme.onError,
                              icon: Icons.delete,
                              label: isZh ? '删除' : 'Delete',
                            ),
                          ],
                        ),
                        child: Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: conv.isPinned
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            child: Icon(
                              conv.isPinned
                                  ? Icons.push_pin
                                  : Icons.chat_bubble_outline,
                              color: conv.isPinned
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                          ),
                          title: Row(
                            children: [
                              if (conv.isPinned)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Icon(Icons.push_pin,
                                      size: 14,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary),
                                ),
                              Expanded(
                                child: Text(conv.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                          ),
                          // v1.7.31：有草稿时显示草稿预览（带图标提示）
                          subtitle: _drafts[conv.id] != null
                              ? Row(
                                  children: [
                                    Icon(Icons.edit_note,
                                        size: 14,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .tertiary),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        '${_drafts[conv.id]}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .tertiary,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : Text(
                                  conv.lastMessage ?? l.tr('noConversations'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          // v1.7.31：置顶从左滑改为 trailing 图标按钮（避免与抽屉手势冲突）
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  conv.isPinned
                                      ? Icons.push_pin
                                      : Icons.push_pin_outlined,
                                  size: 18,
                                  color: conv.isPinned
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.outline,
                                ),
                                tooltip: isZh
                                    ? (conv.isPinned ? '取消置顶' : '置顶')
                                    : (conv.isPinned ? 'Unpin' : 'Pin'),
                                onPressed: () async {
                                  await context
                                      .read<StorageService>()
                                      .togglePinConversation(
                                          conv.id, !conv.isPinned);
                                  _loadData();
                                },
                              ),
                              Text(
                                '${conv.updatedAt.hour}:${conv.updatedAt.minute.toString().padLeft(2, '0')}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    ChatScreen(conversation: conv),
                              ),
                            ).then((_) => _loadData());
                          },
                          ),
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
