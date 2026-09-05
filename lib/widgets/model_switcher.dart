import 'package:flutter/material.dart';
import '../models/api_config.dart';
import '../screens/api_config_screen.dart';
import '../screens/api_config_edit_screen.dart';
import '../utils/model_name_cleaner.dart';
import 'vendor_avatar.dart';

/// 模型切换器（v1.7.18 需求5）
///
/// 取代旧 DropdownButton + ConstrainedBox(maxWidth:100) 截断长名的方案。
/// - 收起态：横长方形按钮 `🤖 {清洗名} ▾`，`MainAxisSize.min` + `Flexible`
///   + `TextOverflow.ellipsis`，超屏才省略并包 `Tooltip(原始名)`。
/// - 展开态：`PopupMenuButton<ApiConfig?>` 竖列表，每项「清洗名主 + 原始名副」，
///   末项「➕ 编辑模型」value=null。
///
/// 决策 Q3/Q4 已锁：清洗走 [ModelNameCleaner.cleanModelName]；选「➕编辑模型」
/// 由本组件内部 `Navigator.push(SettingsScreen)`，**不**经 onModelChanged
///（后者只承载真模型选中）。
class ModelSwitcher extends StatelessWidget {
  final List<ApiConfig> availableConfigs;
  final ApiConfig? currentConfig;
  final ValueChanged<ApiConfig>? onModelChanged;
  final bool isZh;

  const ModelSwitcher({
    super.key,
    required this.availableConfigs,
    required this.currentConfig,
    required this.onModelChanged,
    required this.isZh,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 无任何配置 → 灰色禁用态 chip，点击直接进设置
    if (availableConfigs.isEmpty) return _buildEmptyChip(context, cs);
    return _buildPopupMenu(context, cs);
  }

  /// 无配置时的灰色提示 chip（点击进设置添加模型）
  Widget _buildEmptyChip(BuildContext context, ColorScheme cs) {
    return GestureDetector(
      onTap: () => _openSettings(context),
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: cs.outlineVariant.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outline.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const VendorAvatar(templateId: 'custom', size: 14),
            const SizedBox(width: 4),
            Text(
              isZh ? '未配置' : 'N/A',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 有配置时的 PopupMenuButton 收起态
  Widget _buildPopupMenu(BuildContext context, ColorScheme cs) {
    final cfg = currentConfig;
    final cleanName = cfg != null
        ? ModelNameCleaner.cleanModelName(cfg.model)
        : (isZh ? '未选模型' : 'No model');
    final hasValidCurrent =
        cfg != null && availableConfigs.any((c) => c.id == cfg.id);

    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
      ),
      child: PopupMenuButton<ApiConfig?>(
        tooltip: isZh ? '切换模型' : 'Switch model',
        onSelected: (v) => _onSelected(v, context),
        itemBuilder: (ctx) => _buildItems(ctx, cs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            VendorAvatar(templateId: cfg?.templateId ?? 'custom', size: 14),
            const SizedBox(width: 4),
            Flexible(
              child: Tooltip(
                message: cfg?.model ?? '',
                child: Text(
                  cleanName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: hasValidCurrent ? cs.primary : cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: cs.primary,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建弹出列表：每个配置（清洗名主+原始名副）+ 分隔 + ➕编辑模型
  /// v1.7.36：长按模型项 → 直接打开该模型的编辑页；点 ➕ → API 配置列表
  List<PopupMenuEntry<ApiConfig?>> _buildItems(BuildContext context, ColorScheme cs) {
    final items = <PopupMenuEntry<ApiConfig?>>[];
    for (final c in availableConfigs) {
      items.add(
        PopupMenuItem<ApiConfig?>(
          value: c,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => _openEditConfig(context, c),
            child: _ModelOption(
              cleanName: ModelNameCleaner.cleanModelName(c.model),
              originalName: c.model,
              templateId: c.templateId,
              cs: cs,
            ),
          ),
        ),
      );
    }
    items.add(const PopupMenuDivider());
    items.add(
      PopupMenuItem<ApiConfig?>(
        value: null,
        child: Row(
          children: [
            Icon(Icons.add_circle_outline, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Text(
              isZh ? '➕ 编辑模型' : '➕ Edit models',
              style: TextStyle(
                fontSize: 13,
                color: cs.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
    return items;
  }

  /// 选中处理：null → 进设置；非空 → onModelChanged
  void _onSelected(ApiConfig? v, BuildContext context) {
    if (v == null) {
      _openSettings(context);
    } else {
      onModelChanged?.call(v);
    }
  }

  /// 跳转 API 配置列表页（选「➕编辑模型」时）。postFrame 避免在 popup 关闭同帧 push。
  void _openSettings(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ApiConfigScreen()),
      );
    });
  }

  /// 长按模型项：先关闭弹窗，再直接打开该模型的编辑页
  void _openEditConfig(BuildContext menuContext, ApiConfig config) {
    final nav = Navigator.of(menuContext, rootNavigator: true);
    Navigator.of(menuContext).pop(); // 关闭弹窗，不触发 onSelected
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nav.push(
        MaterialPageRoute(builder: (_) => ApiConfigEditScreen(config: config)),
      );
    });
  }
}

/// 弹出列表单个模型项：清洗名（主）+ 原始名（副，小字灰）
class _ModelOption extends StatelessWidget {
  final String cleanName;
  final String originalName;
  final String templateId;
  final ColorScheme cs;

  const _ModelOption({
    required this.cleanName,
    required this.originalName,
    required this.templateId,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        VendorAvatar(templateId: templateId, size: 16),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                cleanName,
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (originalName != cleanName)
                Text(
                  originalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
