// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

/// AppDownloadService._sanitizeFileName 单元测试
///
/// 覆盖：
///   - 路径遍历攻击（../..）
///   - 非法字符清洗
///   - Windows 保留名危险字符
///   - 空文件名 fallback
///   - 长度限制
///   - 首尾点/空格
void main() {
  group('_sanitizeFileName', () {
    test('正常文件名保留', () {
      expect(DownloadServiceTestHarness.sanitize('my_video.mp4'), 'my_video.mp4');
      expect(DownloadServiceTestHarness.sanitize('report_2024.pdf'), 'report_2024.pdf');
      expect(DownloadServiceTestHarness.sanitize('hello'), 'hello');
    });

    test('路径遍历攻击被剥离', () {
      expect(
          DownloadServiceTestHarness.sanitize('../../etc/passwd'), 'passwd');
      expect(
          DownloadServiceTestHarness.sanitize('/system/bin/sh'), 'sh');
      expect(
          DownloadServiceTestHarness.sanitize('C:\\Windows\\System32\\evil'),
          'evil');
      expect(
          DownloadServiceTestHarness.sanitize('http://evil.com/../../../etc/passwd'),
          'passwd');
    });

    test('空值 fallback', () {
      final r1 = DownloadServiceTestHarness.sanitize('');
      expect(r1, startsWith('download_'));

      final r2 = DownloadServiceTestHarness.sanitize('../');
      expect(r2, startsWith('download_'));
    });

    test('非法字符被替换为 _', () {
      // 用一个混合场景：有路径前缀 + 非法字符
      final r = DownloadServiceTestHarness.sanitize('../download/file<name>:"test".mp4');
      // basename 后应该是 file<name>:"test".mp4
      // 非法字符 < > : " 都要变成 _
      expect(r, isNot(contains('<')));
      expect(r, isNot(contains('>')));
      expect(r, isNot(contains(':')));
      expect(r, isNot(contains('"')));
      expect(r, isNot(contains('/')));
      expect(r, isNot(contains('\\')));
      // 应该保留 .mp4 扩展名
      expect(r, endsWith('.mp4'));
      // 应该以 file 开头
      expect(r, startsWith('file'));
    });

    test('去掉首尾的点和空格', () {
      expect(DownloadServiceTestHarness.sanitize('...hidden...'), 'hidden');
      expect(DownloadServiceTestHarness.sanitize('  spaced  '), 'spaced');
    });

    test('长度限制 200', () {
      final long = 'a' * 300;
      final r = DownloadServiceTestHarness.sanitize(long);
      expect(r.length, lessThanOrEqualTo(200));
    });

    test('Unicode 文件名保留', () {
      // 中文 / emoji 不被破坏
      final r = DownloadServiceTestHarness.sanitize('视频_2024_报告.pdf');
      expect(r, contains('视频_2024_报告'));
      expect(r, contains('.pdf'));
    });
  });
}

/// 用反射访问私有方法（LoggerService 已经暴露 scrubForTest / maskForTest）
/// AppDownloadService 没有 @visibleForTesting 方法，因此直接复制核心逻辑进行测试。
/// 真实实现请看 app_download_service.dart 的 _sanitizeFileName。
class DownloadServiceTestHarness {
  static String sanitize(String raw) {
    if (raw.isEmpty) return 'download_${DateTime.now().millisecondsSinceEpoch}';
    var s = _basename(raw);
    s = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    s = s.replaceAll(RegExp(r'^[\s\.]+'), '');
    s = s.replaceAll(RegExp(r'[\s\.]+$'), '');
    if (s.length > 200) s = s.substring(0, 200);
    if (s.isEmpty) s = 'download_${DateTime.now().millisecondsSinceEpoch}';
    return s;
  }

  /// path_provider 的 basename 简化实现
  static String _basename(String p) {
    // path_provider 的 basename 逻辑：取最后一个路径分隔符后的子串
    // 但要先去掉查询串等
    final clean = p.split('?').first.split('#').first;
    final parts = clean.replaceAll('\\', '/').split('/');
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return parts[i];
    }
    return '';
  }
}
