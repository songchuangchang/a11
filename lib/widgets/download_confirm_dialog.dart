import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/app_download_service.dart';

class DownloadConfirmDialog extends StatefulWidget {
  final String appName;
  final AppDownloadSource source;

  /// v1.3.1 新：true 时在底部额外显示"目录外/非官方/第三方来源"的明确风险提示
  final bool highlightOutOfCatalog;

  const DownloadConfirmDialog({
    super.key,
    required this.appName,
    required this.source,
    this.highlightOutOfCatalog = false,
  });

  @override
  State<DownloadConfirmDialog> createState() => _DownloadConfirmDialogState();
}

class _DownloadConfirmDialogState extends State<DownloadConfirmDialog> {
  String _saveDir = '';
  String _fileName = '';

  @override
  void initState() {
    super.initState();
    _computePaths();
  }

  Future<void> _computePaths() async {
    final svc = context.read<AppDownloadService>();
    final dir = await svc.getSaveDirectory(widget.appName);
    try {
      final uri = Uri.parse(widget.source.downloadUrl);
      final path = uri.path;
      final apkName = path.split('/').lastWhere(
          (s) => s.toLowerCase().endsWith('.apk'),
          orElse: () => '');
      _fileName = apkName.isNotEmpty
          ? apkName
          : '${widget.appName.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_')}_v${widget.source.version.replaceAll('.', '_')}.apk';
    } catch (_) {
      _fileName =
          '${widget.appName.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_')}_v${widget.source.version.replaceAll('.', '_')}.apk';
    }
    if (mounted) {
      setState(() => _saveDir = dir);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isZh = AppLocalizations.of(context).locale.languageCode == 'zh';

    final trustBadge = switch (widget.source.trustLevel) {
      SourceTrustLevel.official => (label: isZh ? '🟢 官方' : '🟢 Official', color: Colors.green, bg: Colors.green.shade50),
      SourceTrustLevel.trustedThirdParty => (label: isZh ? '🟡 可信第三方' : '🟡 Trusted 3rd-party', color: Colors.orange.shade700, bg: Colors.orange.shade50),
      SourceTrustLevel.unknown => (label: isZh ? '🔴 未知来源' : '🔴 Unknown', color: Colors.red.shade700, bg: Colors.red.shade50),
    };

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Icon(Icons.security_rounded, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isZh ? '确认下载' : 'Confirm Download',
              maxLines: 1,
              overflow: TextOverflow.fade,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(isZh ? '即将下载以下文件：' : 'About to download:',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? trustBadge.color.withValues(alpha: 0.18) : trustBadge.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: trustBadge.color.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.source.trustLevel == SourceTrustLevel.official
                          ? Icons.verified_user_rounded
                          : widget.source.trustLevel == SourceTrustLevel.trustedThirdParty
                              ? Icons.shield_outlined
                              : Icons.warning_amber_rounded,
                      size: 16,
                      color: trustBadge.color,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(trustBadge.label,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: trustBadge.color,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _InfoRow(
                  label: isZh ? 'APP / 应用' : 'App',
                  value: '${widget.appName} v${widget.source.version}'),
              _InfoRow(label: isZh ? '来源' : 'Source', value: widget.source.sourceName),
              _InfoRow(label: isZh ? '域名' : 'Domain', value: widget.source.sourceDomain),
              _InfoRow(label: isZh ? '大小' : 'Size', value: widget.source.size),
              _InfoRow(label: isZh ? '架构' : 'Arch', value: widget.source.arch),
              _InfoRow(
                  label: isZh ? '链接' : 'URL',
                  value: widget.source.downloadUrl,
                  isPath: true),
              _InfoRow(
                  label: isZh ? '文件名' : 'Filename',
                  value: _fileName.isEmpty ? '...' : _fileName),
              _InfoRow(
                  label: isZh ? '保存位置' : 'Save to',
                  value: _saveDir.isEmpty ? '...' : _saveDir,
                  isPath: true),
              if (widget.source.sha256 != null)
                _InfoRow(
                    label: isZh ? '校验' : 'SHA256',
                    value: widget.source.sha256!,
                    isHash: true),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  // v1.3.3：统一用 colorScheme 系，避免浅色模式硬编码 blue 导致深色模式对比度不足
                  color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: colorScheme.primary.withValues(alpha: 0.4)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 18,
                        color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isZh
                            ? '文件仅保存到上述目录，不会写入其他位置。'
                            : 'File will only be saved to the folder above.',
                        style: TextStyle(
                            fontSize: 12,
                            // v1.3.3：用 onPrimaryContainer 确保在 primaryContainer 背景上对比度达标
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
              // ===== v1.3.1 二合一关键模块：目录外 / 非官方 确定提示 =====
              if (widget.highlightOutOfCatalog) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.red.withValues(alpha: 0.12)
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: Colors.red.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.gpp_bad_outlined,
                          size: 18, color: Colors.red.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZh
                              ? '⚠️ 此来源不在内置官方目录中，属于第三方/联网搜索到的链接。\n'
                                  '请确认：你知道自己在下载什么、来源域名可信、文件 SHA256（如有）与官方一致，再继续。'
                              : '⚠️ This source is OUT OF the built-in catalog (3rd-party / online-only).\n'
                                  'Continue only if you fully trust this URL and the SHA256 (if any) matches the official one!',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.red.shade800,
                              height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(isZh ? '取消' : 'Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saveDir.isEmpty
              ? null
              : () => Navigator.pop(context, true),
          icon: Icon(
            widget.highlightOutOfCatalog
                ? Icons.warning_amber_rounded
                : Icons.verified_user_rounded,
          ),
          label: Text(
            isZh
                ? (widget.highlightOutOfCatalog ? '我已知风险，允许下载' : '允许下载')
                : 'Allow',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isPath;
  final bool isHash;

  const _InfoRow({
    required this.label,
    required this.value,
    this.isPath = false,
    this.isHash = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    )),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              maxLines: isPath || isHash ? 3 : 2,
              overflow: TextOverflow.ellipsis,
              softWrap: true,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
                fontFamily: isPath || isHash ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
