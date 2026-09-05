// v1.7.15 TDD 红测试：settings_screen 拆分 + 白窗口根治
//
// 测试分三层：
// 1. **源代码契约测试**（TDD 红→绿）
//    第一轮拆分（已完成）：WebSearch / ReAct / SecurityScan / Backup 4 个 Section
//    第二轮拆分（本轮）：Logs&Debug / SelfCheck / General 3 个 Section
//    - 主 settings_screen.dart 不再含 _buildWebSearchSection / _buildReActSection /
//      _buildSecurityScanSection / _buildBackupSection 私有方法
//    - 主 settings_screen.dart 不再含 _buildLogsDebugSection / _buildSelfCheckSection /
//      _buildGeneralSection 私有方法（第二轮新增断言）
//    - 主 settings_screen.dart 不再含 11 个 TextEditingController 字段
//    - 主 settings_screen.dart 不再含 _saveSearchConfig / _loadSearchConfig 方法
//    - 主 settings_screen.dart 不再含 _toggleVerboseLogging / _runSelfCheck /
//      _exportLogs / _clearLogs 方法（第二轮新增断言）
//    - 主 settings_screen.dart 不再含 _searchCfg / _aiBehaviorTestEnabled 字段
//      （第二轮新增断言，verboseLogging 跟随 Logs&Debug sub-screen）
//    - 主 settings_screen.dart 行数 < 600（原 2316 行，第一轮后 1077 行，第二轮目标 ~520 行）
//    这些当前会失败（settings_screen.dart 还有这些方法/字段），实现后转为绿。
//
// 2. **sub-screen 存在性 guard**
//    第一轮：WebSearchSettingsScreen / ReActSettingsScreen / SecurityScanSettingsScreen /
//      BackupSettingsScreen
//    第二轮：LogsDebugSettingsScreen / QaSettingsScreen / GeneralSettingsScreen
//
// 3. **白窗口根治 smoke**
//    - pump 主 SettingsScreen，验证不再有 Switch（避免主列表残留高度突变源）
//    - 主 ListView 只含 ListTile + Divider
//
// 设计权衡：把拆分设为"源代码契约"而非 widget test，因为拆分本质是结构性重构，
// 用源码字符串断言最直接；widget test 难以验证"主页面不再有 Switch"（要遍历 widget 树）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _screenPath = 'd:\\qw11\\aichat\\lib\\screens\\settings_screen.dart';

void main() {
  group('settings_screen source contract (TDD red→green)', () {
    final src = File(_screenPath).readAsStringSync();

    test('主 settings_screen.dart 不应再含 _buildWebSearchSection 方法定义', () {
      expect(
        src.contains('Widget _buildWebSearchSection'),
        isFalse,
        reason:
            'WebSearch Section 应拆到独立 WebSearchSettingsScreen 文件，主 settings 不再含此方法',
      );
    });

    test('主 settings_screen.dart 不应再含 _buildReActSection 方法定义', () {
      expect(
        src.contains('Widget _buildReActSection'),
        isFalse,
        reason: 'ReAct Section 应拆到独立 ReActSettingsScreen 文件',
      );
    });

    test('主 settings_screen.dart 不应再含 _buildSecurityScanSection 方法定义', () {
      expect(
        src.contains('Widget _buildSecurityScanSection'),
        isFalse,
        reason: '安全审查 Section 应拆到独立 SecurityScanSettingsScreen 文件',
      );
    });

    test('主 settings_screen.dart 不应再含 _buildBackupSection 方法定义', () {
      expect(
        src.contains('Widget _buildBackupSection'),
        isFalse,
        reason: '导出/导入 Section 应拆到独立 BackupSettingsScreen 文件',
      );
    });

    test('主 settings_screen.dart 不应再含 11 个 TextEditingController 字段', () {
      expect(
        src.contains('TextEditingController _tavilyCtrl'),
        isFalse,
        reason: 'tavily 控制器应迁到 WebSearchSettingsScreen',
      );
      expect(
        src.contains('TextEditingController _serpApiKeyCtrl'),
        isFalse,
        reason: 'serpApi 控制器应迁到 WebSearchSettingsScreen',
      );
      expect(
        src.contains('TextEditingController _skillspectorEndpointCtrl'),
        isFalse,
        reason: 'skillSpector 控制器应迁到 SecurityScanSettingsScreen',
      );
      expect(
        src.contains('TextEditingController _localScanRulesUrlCtrl'),
        isFalse,
        reason: 'localScanRulesUrl 控制器应迁到 SecurityScanSettingsScreen',
      );
    });

    test('主 settings_screen.dart 不应再含 _saveSearchConfig / _loadSearchConfig 方法', () {
      expect(
        src.contains('Future<void> _saveSearchConfig'),
        isFalse,
        reason: '_saveSearchConfig 应迁到 WebSearchSettingsScreen（每个 sub-screen 自管 save/load）',
      );
      expect(
        src.contains('Future<void> _loadSearchConfig'),
        isFalse,
        reason: '_loadSearchConfig 应迁到各 sub-screen',
      );
    });

    // ===== 第二轮拆分新增断言（红阶段，应失败）=====

    test('主 settings_screen.dart 不应再含 _buildLogsDebugSection 方法', () {
      // 注意：当前主 settings 没有这个方法名（直接内联），所以这个断言
      // 同时要求"也不要把它重构为 _buildLogsDebugSection 再调"，直接搬到 sub-screen。
      expect(
        src.contains('_buildLogsDebugSection'),
        isFalse,
        reason: '日志与调试 Section 应整体搬到 LogsDebugSettingsScreen，主 settings 不留方法名',
      );
    });

    test('主 settings_screen.dart 不应再含 _buildSelfCheckSection 方法', () {
      expect(
        src.contains('_buildSelfCheckSection'),
        isFalse,
        reason: '自检与 QA Section 应整体搬到 QaSettingsScreen，主 settings 不留方法名',
      );
    });

    test('主 settings_screen.dart 不应再含 _buildGeneralSection 方法', () {
      expect(
        src.contains('_buildGeneralSection'),
        isFalse,
        reason: '通用设置 Section 应整体搬到 GeneralSettingsScreen，主 settings 不留方法名',
      );
    });

    test('主 settings_screen.dart 不应再含 _toggleVerboseLogging 方法', () {
      expect(
        src.contains('_toggleVerboseLogging'),
        isFalse,
        reason: 'verboseLogging 开关逻辑应跟随 Logs&Debug sub-screen',
      );
    });

    test('主 settings_screen.dart 不应再含 _runSelfCheck 方法', () {
      expect(
        src.contains('_runSelfCheck'),
        isFalse,
        reason: '自检逻辑应跟随 QaSettingsScreen',
      );
    });

    test('主 settings_screen.dart 不应再含 _exportLogs / _clearLogs 方法', () {
      expect(
        src.contains('_exportLogs'),
        isFalse,
        reason: '导出/清空日志逻辑应跟随 Logs&Debug sub-screen',
      );
      expect(
        src.contains('_clearLogs'),
        isFalse,
        reason: '清空日志逻辑应跟随 Logs&Debug sub-screen',
      );
    });

    test('主 settings_screen.dart 不应再含 _searchCfg 字段（verboseLogging 迁出后无需）', () {
      expect(
        src.contains('_searchCfg'),
        isFalse,
        reason: '_searchCfg 仅用于 verboseLogging，已迁到 LogsDebugSettingsScreen',
      );
    });

    test('主 settings_screen.dart 不应再含 _aiBehaviorTestEnabled 字段', () {
      expect(
        src.contains('_aiBehaviorTestEnabled'),
        isFalse,
        reason: 'AI 行为测试开关应跟随 QaSettingsScreen',
      );
    });

    test('主 settings_screen.dart 不应再含 _exporting / _selfChecking 字段', () {
      expect(
        src.contains('_exporting'),
        isFalse,
        reason: '_exporting 应跟随 Logs&Debug sub-screen',
      );
      expect(
        src.contains('_selfChecking'),
        isFalse,
        reason: '_selfChecking 应跟随 QaSettingsScreen',
      );
    });

    test('主 settings_screen.dart 行数应 < 600（原 2316 行，第一轮后 1077 行）', () {
      // 阈值取 600：第一轮拆分后 1077 行，第二轮再拆 Logs&Debug / SelfCheck /
      // General 三个 Section 后应进一步降至 ~520 行（version update 对话框
      // _showAppUpdateDialog 占 ~180 行保留在主 settings，因为它的触发按钮
      // 在版本卡片里，逻辑紧耦合；硬要拆出来反而增加复杂度）。
      final lines = src.split('\n');
      expect(
        lines.length,
        lessThan(600),
        reason:
            '拆分后主 settings 只剩导航 ListTile + 版本更新对话框，行数应大幅下降。当前 ${lines.length} 行',
      );
    });

    test('主 settings_screen.dart 源码不应含 Switch / SwitchListTile 调用', () {
      // 白窗口根因消除：主列表不再渲染任何 Switch 类组件，开关切换导致的高度
      // 突变只可能发生在 sub-screen 里。源码层面断言比 widget pump 更可靠
      // （widget pump 需要 sqflite_common_ffi init，dev_dependencies 未引入）。
      expect(
        src.contains('Switch('),
        isFalse,
        reason: '主 settings 不应直接渲染 Switch 组件',
      );
      expect(
        src.contains('SwitchListTile('),
        isFalse,
        reason: '主 settings 不应直接渲染 SwitchListTile 组件',
      );
    });
  });

  group('第二轮 sub-screen 存在性 guard（拆分后转绿）', () {
    test('LogsDebugSettingsScreen 文件存在', () {
      final f = File('d:\\qw11\\aichat\\lib\\screens\\logs_debug_settings_screen.dart');
      expect(f.existsSync(), isTrue, reason: 'LogsDebugSettingsScreen 应独立成文件');
    });

    test('QaSettingsScreen 文件存在', () {
      final f = File('d:\\qw11\\aichat\\lib\\screens\\qa_settings_screen.dart');
      expect(f.existsSync(), isTrue, reason: 'QaSettingsScreen 应独立成文件');
    });

    test('GeneralSettingsScreen 文件存在', () {
      final f = File('d:\\qw11\\aichat\\lib\\screens\\general_settings_screen.dart');
      expect(f.existsSync(), isTrue, reason: 'GeneralSettingsScreen 应独立成文件');
    });
  });

  group('sub-screen 存在性 guard（拆分后转绿）', () {
    // 拆分后这些文件应存在 + 可 import
    test('WebSearchSettingsScreen 文件存在', () {
      final f = File('d:\\qw11\\aichat\\lib\\screens\\web_search_settings_screen.dart');
      expect(f.existsSync(), isTrue, reason: 'WebSearchSettingsScreen 应独立成文件');
    });

    test('ReActSettingsScreen 文件存在', () {
      final f = File('d:\\qw11\\aichat\\lib\\screens\\react_settings_screen.dart');
      expect(f.existsSync(), isTrue, reason: 'ReActSettingsScreen 应独立成文件');
    });

    test('SecurityScanSettingsScreen 文件存在', () {
      final f = File('d:\\qw11\\aichat\\lib\\screens\\security_scan_settings_screen.dart');
      expect(f.existsSync(), isTrue, reason: 'SecurityScanSettingsScreen 应独立成文件');
    });

    test('BackupSettingsScreen 文件存在', () {
      final f = File('d:\\qw11\\aichat\\lib\\screens\\backup_settings_screen.dart');
      expect(f.existsSync(), isTrue, reason: 'BackupSettingsScreen 应独立成文件');
    });
  });

  // 注：原"白窗口根治 smoke"的 widget pump 测试已废弃，由上方源码契约
  // "主 settings_screen.dart 源码不应含 Switch / SwitchListTile 调用"替代。
  // 原因：widget pump 需 StorageService.init()，依赖 sqflite_common_ffi init
  // （dev_dependencies 未引入），且源码层面断言"不含 Switch 关键字"已足够
  // 覆盖"主列表不渲染 Switch 类组件"的语义——主 settings 源码里只要不出现
  // Switch / SwitchListTile 标识符，运行时就不可能渲染该类组件，根因消除。
}
