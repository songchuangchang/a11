import 'package:flutter/material.dart';

/// 紧凑型切换按钮（v1.7.18 需求2/7）
///
/// 抽自 ChatInput._buildCompactToggle，承载 🌐搜索 / 🧠思考 / 🔌插件 三处复用。
/// 图标 + emoji 标签，比 IconButton 更小；支持 badge（角标）与 onLongPress。
///
/// 需求7：🌐/🧠 的 onLongPress 由调用方注入「弹 SnackBar 提示左滑打开快速菜单」，
/// 🔌 的 onLongPress 注入 onEditPluginHint（长按弹插件面板）——本组件不感知语义，
/// 仅按注入的回调执行。
class ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool active;
  final String tooltip;
  final String? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.active,
    required this.tooltip,
    this.badge,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = !enabled
        ? cs.outline
        : active
            ? cs.primary
            : cs.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: active ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: active
              ? Border.all(color: cs.primary.withValues(alpha: 0.4))
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, size: 18, color: iconColor),
                if (badge != null)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 3, vertical: 0),
                      decoration: BoxDecoration(
                        color: active ? cs.primary : cs.error,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      constraints: const BoxConstraints(minWidth: 14),
                      alignment: Alignment.center,
                      child: Text(
                        badge!,
                        style: TextStyle(
                          fontSize: badge!.length > 2 ? 6.5 : 8,
                          fontWeight: FontWeight.bold,
                          color: active ? cs.onPrimary : cs.onError,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 10, color: iconColor),
            ),
          ],
        ),
      ),
    );
  }
}
