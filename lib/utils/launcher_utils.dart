import 'package:url_launcher/url_launcher.dart';
import '../services/biometric_service.dart';
import '../services/logger_service.dart';

/// 外链打开公共工具（v1.7.18 抽自 api_config_edit_screen._openUrl 模式）
///
/// 统一所有「在系统浏览器打开外链」的场景：
/// - 安全审查设置页 MobSF/SkillSpector/VirusTotal 官网（需求4）
/// - API 配置编辑页服务商官网（可选去重）
/// - 后续新增的外链场景
///
/// 注意：conversation_list_screen 的「下载文件夹」走 SAF content:// scheme，
/// 仍是原 launchUrl 调用，不属于本工具职责（不同场景，勿强行统一）。
class LauncherUtils {
  static final _logger = LoggerService.instance;

  /// 在系统浏览器中打开指定 URL。
  ///
  /// 流程：canLaunchUrl 守卫 → LaunchMode.externalApplication 打开。
  /// 返回 true 表示成功唤起系统浏览器，false 表示无法打开（调用方可弹 SnackBar 兜底）。
  static Future<bool> openExternalUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      _logger.warn('[Launcher] openExternalUrl: empty url', tag: 'Launcher');
      return false;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      _logger.warn('[Launcher] openExternalUrl: invalid uri "$trimmed"', tag: 'Launcher');
      return false;
    }
    try {
      // canLaunchUrl 守卫：部分 Android 设备对外链 scheme 查询受限，
      // 守卫失败时仍尝试直接 launchUrl（externalApplication），给一次机会。
      final canLaunch = await canLaunchUrl(uri);
      if (!canLaunch) {
        _logger.info('[Launcher] canLaunchUrl=false for "$trimmed"，仍尝试直接打开', tag: 'Launcher');
      }
      final ok = await BiometricService.guardActivityTransition(
        () => launchUrl(uri, mode: LaunchMode.externalApplication),
        fallbackDuration: const Duration(seconds: 120),
      );
      if (!ok) {
        _logger.warn('[Launcher] launchUrl returned false for "$trimmed"', tag: 'Launcher');
      }
      return ok;
    } catch (e, st) {
      _logger.error('[Launcher] openExternalUrl 失败: $e', error: e, stack: st, tag: 'Launcher');
      return false;
    }
  }
}
