import 'package:flutter/material.dart';
import 'quick_access_menu_items.dart';

/// 左滑快速抽屉（v1.7.18 需求6）
///
/// 接入方式：`Scaffold.drawer = QuickAccessDrawer(isZh: isZh)`。
/// Flutter `Drawer` 默认吃边缘左滑手势；AppBar.leading 的汉堡图标调
/// `Scaffold.of(context).openDrawer()` 提供第二入口。
///
/// 菜单项点击：先 `Navigator.pop` 关闭抽屉，再 `Navigator.push` 进入目标页
/// （pop-then-push 顺序，确保抽屉收起且目标页正常打开；若 push-then-pop
/// 会误关刚打开的目标页）。
class QuickAccessDrawer extends StatelessWidget {
  final bool isZh;

  const QuickAccessDrawer({super.key, required this.isZh});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: cs.primaryContainer),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.bolt_rounded, size: 40, color: cs.primary),
                  const SizedBox(height: 8),
                  Text(
                    isZh ? 'Nexus 快速菜单' : 'Nexus Quick Menu',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isZh ? '左滑/汉堡图标随时唤起' : 'Swipe left / tap burger anytime',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onPrimaryContainer.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            for (final item in kQuickAccessMenuItems)
              ListTile(
                leading: Icon(item.icon, color: cs.primary),
                title: Text(isZh ? item.zhLabel : item.enLabel),
                onTap: () => _openTarget(context, item),
              ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.close, color: cs.onSurfaceVariant),
              title: Text(isZh ? '关闭菜单' : 'Close menu'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 关闭抽屉后进入目标 sub-screen。
  void _openTarget(BuildContext context, QuickAccessMenuItem item) {
    Navigator.pop(context); // 先收抽屉
    Navigator.push(
      context,
      MaterialPageRoute(builder: item.targetBuilder),
    );
  }
}
