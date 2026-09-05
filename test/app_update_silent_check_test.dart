// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:aichat/services/app_update_service.dart';

/// v1.7.13 TDD：APP 启动静默更新检查"只跑一次"测试
///
/// 触发背景（nexus_export_2026-08-25T10-51-47 日志）：
///   10:48:14 - AppUpdate: 开始检查更新
///   10:48:16 - AppUpdate: 开始检查更新（2 秒内第 2 次！）
///   10:48:17 - AppUpdate: 开始检查更新（第 3 次）
///   10:48:18 - AppUpdate: 开始检查更新（第 4 次）
///   10:48:19 - AppUpdate: 开始检查更新（第 5 次）
///   ...5 秒内打了 5 次相同的 GitHub API
///
/// 根因：main.dart 的 FutureBuilder builder 闭包里调
///   WidgetsBinding.instance.addPostFrameCallback(...)
/// 每次 builder rebuild 都会再注册一次 post-frame callback，
/// FutureBuilder 频繁 rebuild → 启动检查被反复触发，可能撞 GitHub 速率限制。
///
/// 修复：把启动静默检查包成 AppUpdateService.markStartupSilentCheckRun() +
/// hasRunStartupSilentCheck 守卫，第二次调用直接 return。
void main() {
  group('AppUpdateService 启动静默检查 one-shot 守卫', () {
    setUp(() {
      // 每个测试前重置守卫标志，确保测试间隔离
      AppUpdateService.resetSilentCheckGuardForTest();
    });

    test('resetSilentCheckGuardForTest 后 hasRunStartupSilentCheck 应为 false', () {
      expect(AppUpdateService.hasRunStartupSilentCheck, isFalse);
    });

    test('markStartupSilentCheckRun 后 hasRunStartupSilentCheck 应为 true', () {
      AppUpdateService.markStartupSilentCheckRun();
      expect(AppUpdateService.hasRunStartupSilentCheck, isTrue);
    });

    test('已标记后再次 markStartupSilentCheckRun 不改变状态（幂等）', () {
      AppUpdateService.markStartupSilentCheckRun();
      AppUpdateService.markStartupSilentCheckRun();
      AppUpdateService.markStartupSilentCheckRun();
      expect(AppUpdateService.hasRunStartupSilentCheck, isTrue);
    });

    test('resetSilentCheckGuardForTest 能把守卫重置回 false', () {
      AppUpdateService.markStartupSilentCheckRun();
      expect(AppUpdateService.hasRunStartupSilentCheck, isTrue);
      AppUpdateService.resetSilentCheckGuardForTest();
      expect(AppUpdateService.hasRunStartupSilentCheck, isFalse);
    });
  });
}
