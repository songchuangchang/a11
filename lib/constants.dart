/// 全局常量集中管理
///
/// 放在独立文件里避免循环依赖（BackupService ↔ LoggerService）。
/// 修改版本号时同步修改：pubspec.yaml / settings_screen.dart / 本文件
library constants;

const String kAppVersionConst = '1.7.36+84'; // build84：思考强度0.1连续滑杆/搜索来源可点可复制/代码块一键复制/表格CSV复制下载/厂商favicon图标/亮色主题补齐+列表气泡精修
