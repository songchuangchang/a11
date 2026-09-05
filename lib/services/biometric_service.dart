import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'logger_service.dart';

class BiometricService {
  BiometricService._();

  static final _auth = LocalAuthentication();
  static final _logger = LoggerService.instance;

  /// v1.7.30：标记 App 内原生 Activity 跳转（相机/相册/文档选择器/外链/文件打开），
  /// 避免 didChangeAppLifecycleState 误判为"从后台返回"而重新触发生物锁。
  static bool inAppActivityTransition = false;

  /// v1.7.30：包裹会拉起原生 Activity 的异步操作，设置标志避免返回时重新上锁。
  ///
  /// - startActivityForResult 风格（image_picker, FilePicker）：await 阻塞到用户返回，
  ///   onResume 紧随 onActivityResult，2 秒兜底足够。
  /// - fire-and-forget 风格（url_launcher, OpenFilex）：await 立即返回，
  ///   需更长兜底覆盖用户在外部 App 的短暂停留（默认 120 秒）。
  static Future<T> guardActivityTransition<T>(
    Future<T> Function() action, {
    Duration fallbackDuration = const Duration(seconds: 2),
  }) async {
    inAppActivityTransition = true;
    try {
      return await action();
    } finally {
      Future.delayed(fallbackDuration, () {
        inAppActivityTransition = false;
      });
    }
  }

  /// v1.7.36：可用性放宽——无指纹/面部的设备只要有系统锁屏（PIN/图案/密码）
  /// 也视为可用（isDeviceSupported 含设备凭据），应用锁 UI 不再整个消失。
  static Future<bool> get isAvailable async {
    try {
      return await _auth.isDeviceSupported() ||
          await _auth.canCheckBiometrics;
    } on PlatformException catch (e) {
      _logger.warn('Biometric check failed: $e', tag: 'BIOMETRIC');
      return false;
    }
  }

  static Future<List<BiometricType>> get availableBiometrics async {
    try {
      return await _auth.getAvailableBiometrics();
    } on PlatformException {
      return [];
    }
  }

  static Future<bool> authenticate({required String reason}) async {
    try {
      final canCheck = await isAvailable;
      if (!canCheck) {
        _logger.warn('Biometric not available on this device', tag: 'BIOMETRIC');
        return false;
      }
      // v1.7.36：biometricOnly 改 false，无指纹设备自动降级为系统锁屏
      // PIN/图案/密码验证（local_auth 在 biometricOnly:false 时允许设备凭据）。
      final didAuth = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
      _logger.app('Biometric auth result: $didAuth');
      return didAuth;
    } on PlatformException catch (e) {
      _logger.error('Biometric auth error: $e', tag: 'BIOMETRIC');
      return false;
    }
  }

  static String get biometricTypeName {
    return 'biometric';
  }
}