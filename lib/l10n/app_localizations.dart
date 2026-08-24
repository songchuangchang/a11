import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static final Map<String, Map<String, String>> _localizedValues = {
    'en': {
      // --- Onboarding / Language ---
      'selectLanguage': 'Select Language',
      'selectLanguageSubtitle': 'Choose your preferred language',
      'continueBtn': 'Continue',
      'chinese': 'Chinese (Simplified)',
      'english': 'English',

      // --- App ---
      'appTitle': 'Nexus',

      // --- Conversation List ---
      'noConversations': 'No conversations yet',
      'newChat': 'New Chat',
      'clearMessages': 'Clear messages',

      // --- Chat ---
      'startChattingWith': 'Start chatting with {model}',
      'apiConfigNotFound': 'API configuration not found',
      'goBack': 'Go Back',
      'typeAMessage': 'Type a message...',
      'send': 'Send',
      'stop': 'Stop',

      // --- API Config ---
      'apiSettings': 'API Settings',
      'apiConfigs': 'API Configurations',
      'apiConfigsSubtitle': 'Manage API providers',
      'addApiConfig': 'Add API Config',
      'editApiConfig': 'Edit API Config',
      'selectTemplate': 'Quick select a template',
      'selectTemplateSubtitle':
          'Tap a chip below to auto-fill Base URL and recommended model; you only need to paste your API Key.',
      'configName': 'Config Name',
      'baseUrl': 'Base URL',
      'apiKey': 'API Key',
      'model': 'Model',
      'systemPrompt': 'System Prompt (optional)',
      'temperature': 'Temperature',
      'maxTokens': 'Max Tokens',
      'save': 'Save',
      'delete': 'Delete',
      'cancel': 'Cancel',
      'testConnection': 'Test Connection',
      'connectionOk': 'Connection successful!',
      'connectionFailed': 'Connection failed',

      // --- Settings ---
      'settings': 'Settings',
      'about': 'About',
      'aboutSubtitle': 'About Nexus',
      'storage': 'Storage',
      'storageSubtitle': 'Data stored locally via SQLite',
      'supportedApis': 'Supported APIs',
      'supportedApisSubtitle': 'Any OpenAI-compatible API',
      'supportedApiProviders': 'Supported API Providers',
      'language': 'Language',
      'languageSubtitle': 'Change display language',
      'systemLanguage': 'Follow System',
      'appDownloads': 'App Downloads',
      'appDownloadsSubtitle': 'Manage downloaded APK files',
      'ok': 'OK',

      // --- App Download Feature ---
      'downloadApp': 'Download App',
      'searchingApp': 'Searching for download sources...',
      'foundSources': 'Found the following download options:',
      'sourceOfficial': 'Official',
      'sourceTrustedThirdParty': 'Trusted 3rd Party',
      'sourceUnknown': 'Unknown / Risk',
      'version': 'Version',
      'size': 'Size',
      'arch': 'Arch',
      'securityLevel': 'Security',
      'officialSigned': 'Official signature, safe and reliable',
      'thirdPartyWarn': 'Third-party platform, official source recommended',
      'unknownRisk': 'Unknown source, not recommended',
      'viewDetails': 'View Details',
      'chooseSource': 'Choose this source',
      'confirmDownload': 'Confirm Download',
      'confirmDownloadMsg': 'About to download the following file:',
      'fileName': 'File name',
      'saveLocation': 'Save location',
      'sourceUrl': 'Source URL',
      'checksum': 'SHA256 Checksum',
      'allowDownload': 'Allow Download',
      'downloading': 'Downloading...',
      'downloadComplete': 'Download complete!',
      'downloadFailed': 'Download failed',
      'openFolder': 'Open Folder',
      'installApk': 'Install APK',
      'fileSavedTo': 'File saved to:',
      'integrityVerified': 'File integrity verified (checksum matched)',
      'integrityFailed': 'File integrity check FAILED, file may be corrupted',
      'checksumNotProvided': 'Checksum not provided by source',

      // --- Logs ---
      'viewLogs': 'View Logs',
      'viewLogsSubtitle': 'View recent app runtime logs',
      'exportLogs': 'Export Logs',
      'exportLogsSubtitle': 'Export all logs to a single txt file',
      'clearLogs': 'Clear Logs',
      'clearLogsSubtitle': 'Delete all log files from device',
      'clearLogsConfirm': 'Are you sure to clear ALL logs? This cannot be undone.',
      'clear': 'Clear',
      'open': 'Open',
      'openFailed': 'Open failed',
      'logExportedTo': 'Log exported to',
      'exportFailed': 'Export failed',
      'logsCleared': 'Logs cleared',
      'copied': 'Copied to clipboard',
      'copyAll': 'Copy All',
      'autoScrollOn': 'Auto-scroll: ON (tap to pause)',
      'autoScrollOff': 'Auto-scroll: OFF (tap to resume)',
      'noLogs': 'No logs yet. Send a message or test a connection to generate logs.',

      // --- Web Search (v1.3.0) ---
      'webSearch': 'Web Search',
      'webSearchSubtitle': 'Enable online search for AI responses',
      'webSearchMaster': 'Master Switch',
      'webSearchMasterSubtitleOn': 'All online features enabled (chat search + app download search)',
      'webSearchMasterSubtitleOff': 'Online search disabled. App download for non-built-in apps will prompt to enable this.',
      'webSearchProvider': 'Search Provider',
      'webSearchProviderBing': 'Bing (no key required)',
      'webSearchProviderTavily': 'Tavily (API Key required)',
      'webSearchProviderSearxng': 'SearXNG (self-hosted)',
      'tavilyApiKey': 'Tavily API Key',
      'tavilyApiKeyHint': 'tvly-xxxxxxxxxxxx',
      'tavilyDepth': 'Search Depth',
      'tavilyDepthBasic': 'Basic (fast)',
      'tavilyDepthAdvanced': 'Advanced (accurate)',
      'tavilyMaxResults': 'Results Count',
      'searxngInstance': 'SearXNG Instance URL',
      'searxngInstanceHint': 'https://your-searxng.example.com',
      'providerNotUsable': 'Current provider misconfigured, will fallback to Bing',
      'webSearchSaved': 'Web search settings saved',
      'tavilyKeyMasked': 'Tavily Key saved (masked: ***)',

      // --- Chat Input Search Button (v1.3.0) ---
      'searchModeOn': 'Web search ENABLED for next message',
      'searchModeOff': 'Normal chat (no web search)',
      'searchModeDisabled': 'Web search is disabled in Settings',
      'searchDisabledHint': 'Web search disabled. Go to Settings → Web Search to enable.',
      'searchingNow': 'Searching the web...',
      'searchResultCount': 'Found {count} results, injected into context.',
      'searchResultEmpty': 'No search results found. Answering with internal knowledge.',
      'aiKnowledgeWarning': '⚠️ This response is based on AI internal knowledge and may be outdated. Tap 🌐 in the input bar to enable real-time web search.',
      'aiKnowledgeWarningShort': '⚠️ Based on AI internal knowledge — may be outdated.',
      'goToSettings': 'Go to Settings',

      // --- Download AI-Enhanced (v1.3.0) ---
      'aiDownloadIntro': 'I can help you find & download apps. Tell me the app name, e.g. "download WeChat".',
      'aiDownloadNeedsWeb': 'App search requires web search to be enabled. Open Settings?',
      'aiDownloadPrecheckDialog': '⚠️ App Download Notice',
      'aiDownloadPrecheckBuiltin': 'This app is in the built-in catalog — sources verified ✅',
      'aiDownloadPrecheckWeb': '🌐 This app is NOT in the built-in catalog. Real-time web search will be used; sources found online are third-party and need your confirmation before download.',
      'aiDownloadPrecheckWebOff': 'Web search is OFF. Only built-in catalog can be used. Enable web search in Settings to find more apps.',
      'aiKnowledgeDisclaimer': 'ℹ️ Note: Any app name I recall comes from my training data and may be outdated. I will verify real availability via web search before presenting links.',
      'confirmContinue': 'Continue',

      // --- v1.3.1 Search Connection Test + LLM Intent ---
      'testSearchConnection': 'Test Search Connection',
      'testSearchConnectionSaving': 'Saving…',
      'testSearchConnectionTesting': 'Testing…',
      'searchTestSuccess': '✅ Search connection OK: {msg}',
      'searchTestFail': '❌ Search connection failed: {msg}',
      'searchTestNoConfig': 'No search provider selected. Configure at least one provider first.',
      'searchTestTavilyKeyEmpty': 'Tavily API Key is empty.',
      'searchTestSearxngUrlEmpty': 'SearXNG instance URL is empty.',
      'searchTestBingKeyEmpty': 'Bing Custom Search API Key is empty.',
      'searchTestBingConfigEmpty': 'Bing Custom Search ID is empty.',

      // --- Logging categories (v1.3.0 enhancement) ---
      'logPrivacyNote': 'Logs never include chat content, full API Keys, or personal info. Keys are always masked as ***.',
      'logPrivacyTag': '🔒 Privacy-first logging',

      // --- Security Scan (v1.7.5) ---
      'securityScan': 'Security Scan',
      'securityScanSubtitle': 'Configure SkillSpector and MobSF services',
      'skillspectorEndpoint': 'SkillSpector Endpoint',
      'skillspectorEndpointHint': 'http://192.168.1.100:8000',
      'enableSkillSecurityScan': 'Enable Skill Security Scan',
      'enableMcpSecurityScan': 'Enable MCP Security Scan',
      'mobsfEndpoint': 'MobSF Endpoint',
      'mobsfEndpointHint': 'http://192.168.1.100:8080',
      'enableApkSecurityScan': 'Enable APK Security Scan',
      // v1.7.9：删除与上方重复的 testConnection/connectionFailed（equal_keys warning）
      'connectionSuccess': 'Connection successful',
      'scanning': 'Running security scan...',
      'scanResult': 'Security Scan Result',
      'riskScore': 'Risk Score',
      'lowRisk': 'Low Risk',
      'mediumRisk': 'Medium Risk',
      'highRisk': 'High Risk',
      'criticalRisk': 'Critical Risk',
      'findings': 'Findings',
      'unsafeWarning': 'This plugin has security risks, install with caution',
      'continueInstall': 'Continue',
      'cancelled': 'Installation cancelled',
      'updateAvailable': 'Update Available',
      'update': 'Update',
      'currentVersion': 'Current',
      'latestVersion': 'Latest',
      'checkingUpdates': 'Checking for updates...',
      'noUpdates': 'All plugins are up to date',
    },
    'zh': {
      // --- 引导 / 语言 ---
      'selectLanguage': '选择语言',
      'selectLanguageSubtitle': '请选择你偏好的显示语言',
      'continueBtn': '继续',
      'chinese': '简体中文',
      'english': 'English',

      // --- App ---
      'appTitle': 'Nexus',

      // --- 会话列表 ---
      'noConversations': '还没有会话',
      'newChat': '新建聊天',
      'clearMessages': '清空消息',

      // --- 聊天 ---
      'startChattingWith': '开始和 {model} 对话',
      'apiConfigNotFound': '找不到 API 配置',
      'goBack': '返回',
      'typeAMessage': '输入消息...',
      'send': '发送',
      'stop': '停止',

      // --- API 配置 ---
      'apiSettings': 'API 设置',
      'apiConfigs': 'API 配置',
      'apiConfigsSubtitle': '管理 API 服务商',
      'addApiConfig': '添加 API 配置',
      'editApiConfig': '编辑 API 配置',
      // v1.7.9 (M17 修复)：补齐缺失的 2 个 key（之前 zh 只有 173 个 / en 175 个，
      // 中文界面 API 编辑页回落英文）
      'selectTemplate': '快速选择模板',
      'selectTemplateSubtitle': '选一个常用服务商模板，自动填入地址和模型',
      'configName': '配置名称',
      'baseUrl': '服务地址',
      'apiKey': 'API 密钥',
      'model': '模型',
      'systemPrompt': '系统提示词（可选）',
      'temperature': '温度',
      'maxTokens': '最大 Token',
      'save': '保存',
      'delete': '删除',
      'cancel': '取消',
      'testConnection': '测试连接',
      'connectionOk': '连接成功！',
      'connectionFailed': '连接失败',

      // --- 设置 ---
      'settings': '设置',
      'about': '关于',
      'aboutSubtitle': '关于 Nexus',
      'storage': '存储',
      'storageSubtitle': '数据通过 SQLite 保存在本地',
      'supportedApis': '支持的 API',
      'supportedApisSubtitle': '任何兼容 OpenAI 协议的 API',
      'supportedApiProviders': '支持的 API 服务商',
      'language': '语言',
      'languageSubtitle': '切换显示语言',
      'systemLanguage': '跟随系统',
      'appDownloads': '应用下载',
      'appDownloadsSubtitle': '管理已下载的 APK 安装包',
      'ok': '好的',

      // --- APP 下载功能 ---
      'downloadApp': '下载 APP',
      'searchingApp': '正在搜索下载来源...',
      'foundSources': '找到以下下载选项：',
      'sourceOfficial': '官方',
      'sourceTrustedThirdParty': '可信第三方',
      'sourceUnknown': '未知 / 有风险',
      'version': '版本',
      'size': '大小',
      'arch': '架构',
      'securityLevel': '安全性',
      'officialSigned': '官方签名，安全可靠',
      'thirdPartyWarn': '第三方平台，建议优先官方',
      'unknownRisk': '来源不明，不推荐下载',
      'viewDetails': '查看详情',
      'chooseSource': '选择此源下载',
      'confirmDownload': '确认下载',
      'confirmDownloadMsg': '即将下载以下文件：',
      'fileName': '文件名',
      'saveLocation': '保存位置',
      'sourceUrl': '来源链接',
      'checksum': '校验值',
      'allowDownload': '允许下载',
      'downloading': '下载中...',
      'downloadComplete': '下载完成！',
      'downloadFailed': '下载失败',
      'openFolder': '打开文件夹',
      'installApk': '安装 APK',
      'fileSavedTo': '文件已保存到：',
      'integrityVerified': '文件完整性校验通过（校验值匹配）',
      'integrityFailed': '文件完整性校验失败，文件可能损坏',
      'checksumNotProvided': '来源未提供校验值',

      // --- 日志 ---
      'viewLogs': '查看日志',
      'viewLogsSubtitle': '查看最近的运行日志',
      'exportLogs': '导出日志',
      'exportLogsSubtitle': '把所有日志打包成一个 txt 文件',
      'clearLogs': '清空日志',
      'clearLogsSubtitle': '删除设备上的所有日志文件',
      'clearLogsConfirm': '确定要清空所有日志吗？此操作不可撤销。',
      'clear': '清空',
      'open': '打开',
      'openFailed': '打开失败',
      'logExportedTo': '日志已导出到',
      'exportFailed': '导出失败',
      'logsCleared': '日志已清空',
      'copied': '已复制到剪贴板',
      'copyAll': '复制全部',
      'autoScrollOn': '自动滚动：开（点一下暂停）',
      'autoScrollOff': '自动滚动：关（点一下恢复）',
      'noLogs': '还没有日志。发条消息或测试一下连接就会产生日志。',

      // --- 联网搜索 (v1.3.0) ---
      'webSearch': '联网搜索',
      'webSearchSubtitle': '让 AI 在回答前先搜索最新信息',
      'webSearchMaster': '总开关',
      'webSearchMasterSubtitleOn': '已启用：聊天联网搜索 + 应用下载搜索均可使用',
      'webSearchMasterSubtitleOff': '已关闭。若要下载内置目录以外的 APP，会提示你先打开此开关。',
      'webSearchProvider': '搜索服务商',
      'webSearchProviderBing': '必应 Bing（免 Key，国内可用）',
      'webSearchProviderTavily': 'Tavily（需 API Key，结果更精准）',
      'webSearchProviderSearxng': 'SearXNG（自建/公共实例）',
      'tavilyApiKey': 'Tavily API Key',
      'tavilyApiKeyHint': 'tvly-xxxxxxxxxxxx',
      'tavilyDepth': '搜索深度',
      'tavilyDepthBasic': '基础（快速）',
      'tavilyDepthAdvanced': '高级（精准）',
      'tavilyMaxResults': '返回结果数量',
      'searxngInstance': 'SearXNG 实例地址',
      'searxngInstanceHint': 'https://你的-searxng.域名.com',
      'providerNotUsable': '当前搜索服务商配置不完整，将自动回退到 Bing',
      'webSearchSaved': '联网搜索设置已保存',
      'tavilyKeyMasked': 'Tavily Key 已保存（已脱敏：***）',

      // --- 输入框搜索按钮 (v1.3.0) ---
      'searchModeOn': '下一条消息将联网搜索',
      'searchModeOff': '普通聊天（不联网搜索）',
      'searchModeDisabled': '已在设置中关闭联网搜索',
      'searchDisabledHint': '联网搜索已关闭。请前往 设置 → 联网搜索 中打开。',
      'searchingNow': '正在上网搜索...',
      'searchResultCount': '找到 {count} 条结果，已注入到回答上下文中。',
      'searchResultEmpty': '联网搜索未找到结果，将使用 AI 内置知识回答。',
      'aiKnowledgeWarning': '⚠️ 以下内容基于 AI 训练数据生成，可能已过时。点击输入框旁的 🌐 可实时联网搜索最新内容。',
      'aiKnowledgeWarningShort': '⚠️ 基于 AI 内置知识，可能已过时。',
      'goToSettings': '前往设置',

      // --- 下载 AI 强化 (v1.3.0) ---
      'aiDownloadIntro': '我可以帮你查找并下载 APP。告诉我应用名称即可，例如"帮我下载微信"。',
      'aiDownloadNeedsWeb': '下载 APP 需要联网搜索才能工作。要打开设置吗？',
      'aiDownloadPrecheckDialog': '⚠️ APP 下载提示',
      'aiDownloadPrecheckBuiltin': '此 APP 在官方内置目录中，来源已验证 ✅',
      'aiDownloadPrecheckWeb': '🌐 此 APP 不在内置目录中，将通过实时联网搜索查找来源；搜索到的第三方链接需要你确认后才会下载。',
      'aiDownloadPrecheckWebOff': '联网搜索已关闭，只能使用内置目录。请在设置中打开联网搜索以获取更多来源。',
      'aiKnowledgeDisclaimer': 'ℹ️ 提示：我识别到的 APP 名称来自 AI 训练数据，可能不是最新版本。我会通过实时联网搜索确认真实下载地址后再展示给你。',
      'confirmContinue': '继续',

      // --- v1.3.1 搜索连接测试 + LLM 下载意图 ---
      'testSearchConnection': '测试搜索连接 / Test',
      'testSearchConnectionSaving': '保存配置中…',
      'testSearchConnectionTesting': '测试中…',
      'searchTestSuccess': '✅ 搜索连接正常：{msg}',
      'searchTestFail': '❌ 搜索连接失败：{msg}',
      'searchTestNoConfig': '未选择任何搜索服务商，请先配置至少一种。',
      'searchTestTavilyKeyEmpty': 'Tavily API Key 为空。',
      'searchTestSearxngUrlEmpty': 'SearXNG 实例地址为空。',
      'searchTestBingKeyEmpty': 'Bing 自定义搜索 API Key 为空。',
      'searchTestBingConfigEmpty': 'Bing 自定义搜索配置 ID 为空。',

      // --- 日志隐私 (v1.3.0) ---
      'logPrivacyNote': '日志绝不记录聊天内容、完整 API Key 或任何个人敏感信息。所有 Key 均已脱敏为 ***。',
      'logPrivacyTag': '🔒 隐私优先的日志记录',

      // --- 安全审查 (v1.7.5) ---
      'securityScan': '安全审查',
      'securityScanSubtitle': '配置 SkillSpector 和 MobSF 服务',
      'skillspectorEndpoint': 'SkillSpector 端点',
      'skillspectorEndpointHint': 'http://192.168.1.100:8000',
      'enableSkillSecurityScan': '启用 Skill 安全审查',
      'enableMcpSecurityScan': '启用 MCP 安全审查',
      'mobsfEndpoint': 'MobSF 端点',
      'mobsfEndpointHint': 'http://192.168.1.100:8080',
      'enableApkSecurityScan': '启用 APK 安全审查',
      // v1.7.9：删除与上方重复的 testConnection/connectionFailed（equal_keys warning）
      'connectionSuccess': '连接成功',
      'scanning': '正在进行安全审查...',
      'scanResult': '安全审查结果',
      'riskScore': '风险评分',
      'lowRisk': '低风险',
      'mediumRisk': '中风险',
      'highRisk': '高风险',
      'criticalRisk': '极高风险',
      'findings': '发现的问题',
      'unsafeWarning': '此插件存在安全风险，建议谨慎安装',
      'continueInstall': '继续安装',
      'cancelled': '已取消安装',
      'updateAvailable': '有可用更新',
      'update': '更新',
      'currentVersion': '当前版本',
      'latestVersion': '最新版本',
      'checkingUpdates': '正在检查更新...',
      'noUpdates': '所有插件已是最新版本',
    },
  };

  String tr(String key, {Map<String, String>? args}) {
    String value = _localizedValues[locale.languageCode]?[key] ??
        _localizedValues['en']?[key] ??
        key;
    if (args != null) {
      args.forEach((k, v) {
        value = value.replaceAll('{$k}', v);
      });
    }
    return value;
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture<AppLocalizations>(AppLocalizations(locale));

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
