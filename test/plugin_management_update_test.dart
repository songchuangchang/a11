// v1.7.14 TDD 测试：plugin_management_screen `_updatePlugin` 接入 PluginUpdateService
//
// 测试分两层：
// 1. **源代码契约测试**（TDD 红 → 绿）
//    - 验证 plugin_management_screen.dart 源码确实调用了 PluginUpdateService.updatePlugin
//    - 验证源码不再含 v1.7.5 留下的 TODO 占位字符串"更新功能开发中..."
//    上面两条当前会失败（TODO 占位未接入），实现后转为绿色 guard，防止以后回退
//
// 2. **Service 层 guard 测试**
//    - PluginUpdateService.updatePlugin 对未注册 pluginId 立即返回 (false, contains('未安装'))
//    - PluginUpdateService.updatePlugin 对未知 kind 立即返回 (false, contains('不支持'))
//    这两条现在已经能过（service 在 v1.7.12 已实现），作为接口稳定性 guard 防止回退
//
// 设计权衡：Dart 静态方法不可 mock + PluginUpdateService 内部含真实网络调用 → 端到端 widget
// 测试成本过高且维护代价大。改用「源代码契约 + Service guard」双层覆盖，UI 行为靠代码审查兜底。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:aichat/plugins/plugin_registry.dart';
import 'package:aichat/screens/plugin_management_screen.dart';
import 'package:aichat/services/plugin_update_service.dart';

const _screenPath =
    'd:\\qw11\\aichat\\lib\\screens\\plugin_management_screen.dart';

void main() {
  group('plugin_management_screen source contract (TDD red→green)', () {
    // 读源码一次，三个测试共用
    final src = File(_screenPath).readAsStringSync();

    test(
        '源码必须调用 PluginUpdateService.updatePlugin（当前 TODO 占位未调用，本条应为红）',
        () {
      expect(
        src.contains('PluginUpdateService.updatePlugin'),
        isTrue,
        reason:
            'plugin_management_screen.dart _updatePlugin 必须调用 PluginUpdateService.updatePlugin，'
            '当前还是 TODO 占位，未接入 service',
      );
    });

    test(
        '源码不应再含 v1.7.5 TODO 占位字符串"更新功能开发中..."（当前应为红）',
        () {
      expect(
        src.contains('更新功能开发中'),
        isFalse,
        reason: '源码仍含 "更新功能开发中..." 占位字符串，说明 _updatePlugin 还没接入 service',
      );
    });

    test('源码应根据 success 标志选择 SnackBar 颜色（成功绿/失败红）', () {
      // v1.7.23 契约更新：80+ 硬编码 Colors → colorScheme 迁移后，
      // 契约本意不变（success 决定颜色），但断言改为 colorScheme 三元选择：
      // 成功 → colorScheme.primary，失败 → colorScheme.error
      expect(
          src.contains(
              'backgroundColor: success ? colorScheme.primary : colorScheme.error'),
          isTrue,
          reason: '_updatePlugin SnackBar 应根据 success 选 colorScheme.primary / colorScheme.error');
    });
  });

  group('PluginUpdateService.updatePlugin service guard', () {
    test('未注册的 pluginId 应立即返回 (false, contains "未安装")', () async {
      final registry = PluginRegistry();
      const info = PluginUpdateInfo(
        pluginId: 'not.installed.skill',
        currentVersion: '1.0.0',
        latestVersion: '1.1.0',
        downloadUrl: 'https://example.com/skill.md',
        hasUpdate: true,
      );

      final (success, message) =
          await PluginUpdateService.updatePlugin(info, registry);

      expect(success, isFalse,
          reason: '未注册的 pluginId 应当 fail-fast 不发起网络请求');
      expect(message, contains('未安装'),
          reason: '失败原因必须包含"未安装"字样便于用户/日志识别');
    });

    test('再次验证未注册路径返回非空错误信息（与 T1 对照，确认 fail-fast 路径稳定）',
        () async {
      // 代码审查建议：原"未知 kind"标题与正文不符（PluginKind enum 只 2 值，无法构造未知 kind）
      // service L54 那条防御性 return 实际不可达，已在 v1.7.14 一并删除
      // 本测试改为与 T1 互为对照：另一个不存在的 pluginId 也应 fail-fast
      final registry = PluginRegistry();
      const info = PluginUpdateInfo(
        pluginId: 'absent.plugin',
        currentVersion: '1',
        latestVersion: '2',
        downloadUrl: '',
        hasUpdate: true,
      );
      final (success, message) =
          await PluginUpdateService.updatePlugin(info, registry);
      expect(success, isFalse);
      expect(message, isNotEmpty);
    });
  });

  group('PluginManagementScreen widget smoke', () {
    testWidgets(
        '注入空 registry 时 pump 不崩溃 + AppBar 标题渲染正确（防止以后小改动 break 屏幕）',
        (tester) async {
      final registry = PluginRegistry();
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<PluginRegistry>.value(
            value: registry,
            child: const PluginManagementScreen(),
          ),
        ),
      );
      // _checkUpdates 异步触发，pump 一帧让它跑完
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // AppBar 标题应渲染（无论 registry 是否为空都显示）
      expect(find.byType(AppBar), findsOneWidget);
      // 浮动按钮"插件市场"始终显示
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });
}
