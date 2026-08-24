import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:open_filex/open_filex.dart';
import '../l10n/app_localizations.dart';
import '../services/app_download_service.dart';
import '../services/logger_service.dart';

class DownloadProgressDialog extends StatefulWidget {
  final String appName;
  final AppDownloadSource source;

  const DownloadProgressDialog({
    super.key,
    required this.appName,
    required this.source,
  });

  @override
  State<DownloadProgressDialog> createState() => _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<DownloadProgressDialog> {
  final LoggerService _log = LoggerService.instance;

  @override
  Widget build(BuildContext context) {
    final task = context.watch<AppDownloadService>().currentTask;
    final colorScheme = Theme.of(context).colorScheme;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';

    if (task == null) {
      // M19 修复：task == null 表示下载尚未启动或已静默失败。
      // 原实现只有 CircularProgressIndicator 无关闭按钮，用户卡死。
      // 这里加"关闭"按钮，让用户能主动 dismiss。
      return AlertDialog(
        content: const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(isZh ? '关闭' : 'Close'),
          ),
        ],
      );
    }

    final complete = task.isComplete && task.error == null;
    final failed = task.error != null;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Expanded(
            child: Text(complete
                ? (isZh ? '✅ 下载完成' : '✅ Download Complete')
                : failed
                    ? (isZh ? '❌ 下载失败' : '❌ Download Failed')
                    : (isZh ? '⬇️ 下载中' : '⬇️ Downloading...')),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!complete && !failed) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                minHeight: 10,
                value: task.progress > 0 ? task.progress : null,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text('${_fmt(task.receivedBytes)} / ${_fmt(task.totalBytes)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Text('${(task.progress * 100).toStringAsFixed(1)}%',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            Text(task.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    )),
          ] else if (complete) ...[
            Icon(Icons.check_circle_rounded,
                size: 64, color: Colors.green.shade500),
            const SizedBox(height: 12),
            Text(task.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    )),
            const SizedBox(height: 6),
            Text(isZh ? '已保存到：' : 'Saved to:',
                style: Theme.of(context).textTheme.bodySmall),
            Text(task.fullPath,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    )),
          ] else ...[
            Icon(Icons.error_outline_rounded,
                size: 64, color: Colors.red.shade400),
            const SizedBox(height: 12),
            Text(task.error ?? 'Unknown error',
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.red.shade300,
                  fontWeight: FontWeight.w500,
                )),
          ],
        ],
      ),
      actions: [
        if (!complete && !failed)
          TextButton(
            onPressed: () {
              context.read<AppDownloadService>().currentTask = null;
              Navigator.pop(context);
            },
            child: Text(isZh ? '后台下载' : 'Background'),
          ),
        if (complete) ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(isZh ? '关闭' : 'Close'),
          ),
          TextButton.icon(
            onPressed: () async {
              try {
                await OpenFilex.open(task.saveDir);
              } catch (e) {
                _log.warn('[Download] Open folder failed: $e');
              }
              if (mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.folder_rounded),
            label: Text(isZh ? '打开文件夹' : 'Open Folder'),
          ),
          FilledButton.icon(
            onPressed: () async {
              try {
                final r = await OpenFilex.open(task.fullPath,
                    type: 'application/vnd.android.package-archive');
                _log.info('[Download] Open APK result: type=${r.type} message=${r.message}');
              } catch (e, st) {
                _log.error('[Download] Open APK failed', error: e, stack: st, tag: 'OpenAPK');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                        isZh ? '安装器打不开，请去文件管理器找：\n${task.fullPath}' : 'Installer failed to open, find it in your file manager:\n${task.fullPath}',
                        maxLines: 4, overflow: TextOverflow.ellipsis),
                  ));
                }
              }
              if (mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.install_mobile_rounded),
            label: Text(isZh ? '安装' : 'Install APK'),
          ),
        ] else if (failed) ...[
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(isZh ? '确定' : 'OK'),
          ),
        ],
      ],
    );
  }

  static String _fmt(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    double size = bytes.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(1)} ${units[unit]}';
  }
}
