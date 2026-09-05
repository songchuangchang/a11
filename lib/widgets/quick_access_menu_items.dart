import 'package:flutter/material.dart';
import '../screens/about_screen.dart';
import '../screens/api_config_screen.dart';
import '../screens/plugin_market_screen.dart';
import '../screens/quick_self_check_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/web_search_settings_screen.dart';

class QuickAccessMenuItem {
  final IconData icon;
  final String zhLabel;
  final String enLabel;
  final WidgetBuilder targetBuilder;

  const QuickAccessMenuItem({
    required this.icon,
    required this.zhLabel,
    required this.enLabel,
    required this.targetBuilder,
  });
}

final List<QuickAccessMenuItem> kQuickAccessMenuItems =
    <QuickAccessMenuItem>[
  QuickAccessMenuItem(
    icon: Icons.settings_outlined,
    zhLabel: '设置',
    enLabel: 'Settings',
    targetBuilder: (_) => const SettingsScreen(),
  ),
  QuickAccessMenuItem(
    icon: Icons.info_outline,
    zhLabel: '关于',
    enLabel: 'About',
    targetBuilder: (_) => const AboutScreen(),
  ),
  QuickAccessMenuItem(
    icon: Icons.cloud_outlined,
    zhLabel: 'API 配置',
    enLabel: 'API Config',
    targetBuilder: (_) => const ApiConfigScreen(),
  ),
  QuickAccessMenuItem(
    icon: Icons.travel_explore,
    zhLabel: '联网搜索',
    enLabel: 'Web Search',
    targetBuilder: (_) => const WebSearchSettingsScreen(),
  ),
  QuickAccessMenuItem(
    icon: Icons.extension_outlined,
    zhLabel: '插件市场',
    enLabel: 'Plugin Market',
    targetBuilder: (_) => const PluginMarketScreen(),
  ),
  QuickAccessMenuItem(
    icon: Icons.verified_user_outlined,
    zhLabel: '快速自检',
    enLabel: 'Quick Self-Check',
    targetBuilder: (_) => const QuickSelfCheckScreen(),
  ),
];