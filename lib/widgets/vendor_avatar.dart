import 'package:flutter/material.dart';

import '../models/api_provider_template.dart';

/// 厂商图标（v1.7.37）：
/// 按 templateId 查模板，优先显示官网 favicon
/// （Google s2/favicons 服务），加载失败/无官网时回退为
/// 「圆角彩色方块 + 模板 IconData」；custom/未知模板显示灰色 🔧 图标。
class VendorAvatar extends StatelessWidget {
  final String templateId;
  final double size;
  final double borderRadius;

  const VendorAvatar({
    super.key,
    required this.templateId,
    this.size = 24,
    this.borderRadius = 6,
  });

  static ApiProviderTemplate? _findTemplate(String id) {
    final list = ApiProviderTemplateCatalog.instance.hasRemote
        ? ApiProviderTemplateCatalog.instance.all
        : ApiProviderTemplate.all;
    for (final t in list) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 官网 favicon URL（无官网则空字符串）
  static String faviconUrl(String templateId) {
    final t = _findTemplate(templateId);
    final url = t?.officialUrl ?? '';
    if (url.isEmpty) return '';
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return '';
    return 'https://www.google.com/s2/favicons?domain=$host&sz=64';
  }

  Widget _fallback(ColorScheme cs) {
    if (templateId == ApiProviderTemplate.customId) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.tertiary.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Icon(Icons.build, size: size * 0.62, color: cs.tertiary),
      );
    }
    final t = _findTemplate(templateId);
    if (t == null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.outlineVariant.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Icon(Icons.build, size: size * 0.62, color: cs.onSurfaceVariant),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: t.color,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Icon(t.icon, size: size * 0.62, color: Colors.white),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fb = _fallback(cs);
    final url = faviconUrl(templateId);
    if (url.isEmpty) return fb;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Container(
        width: size,
        height: size,
        color: Colors.white,
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.contain,
          // 加载中也直接显示回退样式，避免空白闪烁
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : fb,
          errorBuilder: (context, error, stack) => fb,
        ),
      ),
    );
  }
}
