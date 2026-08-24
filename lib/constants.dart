/// 全局常量集中管理
///
/// 放在独立文件里避免循环依赖（BackupService ↔ LoggerService）。
/// 修改版本号时同步修改：pubspec.yaml / settings_screen.dart / 本文件

const String kAppVersionConst = '1.7.11+58';
