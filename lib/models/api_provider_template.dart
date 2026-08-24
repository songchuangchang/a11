import 'package:flutter/material.dart';

/// 单个模型版本选项（用户在 API 配置页可以一键切换）
class ModelOption {
  final String id; // 真实发到 API 的 model 字段
  final String nameZh; // 中文 UI 显示名
  final String nameEn; // 英文 UI 显示名
  final bool recommended; // 是否为推荐默认
  final bool isFreeModel; // 这个具体模型是否官方免费
  final String? noteZh; // 简短特点说明（可选）
  final String? noteEn;

  const ModelOption({
    required this.id,
    required this.nameZh,
    required this.nameEn,
    this.recommended = false,
    this.isFreeModel = false,
    this.noteZh,
    this.noteEn,
  });

  String displayName(bool isZh) => isZh ? nameZh : nameEn;
  String? note(bool isZh) => isZh ? noteZh : noteEn;
}

/// 预置的 OpenAI 兼容 API Provider 模板
///
/// 数据基于 2026-08 官方公开价格/文档核实。
/// 免费标记 **超级严格**（避免误导用户以为"永远白嫌"）：
///   hasFreeTier=true  仅当：该服务商在 API 层面提供
///                        「永久免费、不限调用总次数 / 总量」的免费层
///                        （如 ERNIE-Speed、Gemini-3-Flash 免费 RPM、
///                         Spark-Lite、Ollama 本地）。
///                       *包括 Groq 那种 RPM/RPD 有上限但永久可循环用的也算。
///   hasFreeTier=false  其余所有情况：
///                      · 只有一次性新人赠金 / 限时代金券 / 30 天有效 Tokens
///                        （DeepSeek / Kimi / 腾讯混元 / 阿里云 / 豆包 等）
///                      · 纯网页端免费但 API 全付费（MiniMax 等）
///                      · 欢迎赠金永久有效但总量有限，用完即止（Kimi 15元）
///   isFreeModel=true   仅对「这个具体模型名」真的是永久免费API层时才标。
///
/// 排序规则：按国内开发者真实调用量（OpenRouter/社区数据）从高到低：
///   国内：DeepSeek → Qwen → 智谱GLM → Kimi → 硅基流动 → MiniMax → 豆包 → 千帆 → 混元 → 星火
///   国际：OpenRouter → OpenAI → Gemini → Groq → Claude → Together
///   本地：Ollama → LM Studio
class ApiProviderTemplate {
  final String id;
  final String nameZh;
  final String nameEn;
  final String defaultConfigName;
  final String baseUrl;
  final String defaultModel;
  final List<ModelOption> models;
  final ApiProviderGroup group;

  /// 是否提供 API 层面的永久免费模型或永久免费额度
  final bool hasFreeTier;

  /// 免费方式的简短说明（用在提示小气泡里）
  final String freeDetailZh;
  final String freeDetailEn;

  final String descZh;
  final String descEn;
  final Color color;
  final IconData icon;

  const ApiProviderTemplate({
    required this.id,
    required this.nameZh,
    required this.nameEn,
    required this.defaultConfigName,
    required this.baseUrl,
    required this.defaultModel,
    this.models = const [],
    required this.group,
    this.hasFreeTier = false,
    this.freeDetailZh = '',
    this.freeDetailEn = '',
    this.descZh = '',
    this.descEn = '',
    this.color = Colors.blue,
    this.icon = Icons.cloud,
  });

  static const String customId = 'custom';
  static const List<ApiProviderTemplate> all = _all;

  /// v1.5.2：服务商官网链接映射（用户点击跳转去注册账号 / 查 API Key）
  static const Map<String, String> _officialUrls = {
    'deepseek': 'https://platform.deepseek.com/',
    'dashscope': 'https://bailian.console.aliyun.com/',
    'glm': 'https://open.bigmodel.cn/',
    'kimi': 'https://platform.moonshot.cn/',
    'siliconflow': 'https://siliconflow.cn/',
    'minimax': 'https://platform.minimaxi.com/',
    'doubao': 'https://console.volcengine.com/ark',
    'qianfan': 'https://qianfan.cloud.baidu.com/',
    'hunyuan': 'https://cloud.tencent.com/product/hunyuan',
    'xfyun': 'https://xinghuo.xfyun.cn/',
    'openrouter': 'https://openrouter.ai/',
    'openai': 'https://platform.openai.com/',
    'gemini': 'https://ai.google.dev/',
    'groq': 'https://console.groq.com/',
    'claude': 'https://console.anthropic.com/',
    'together': 'https://www.together.ai/',
    'ollama': 'https://ollama.com/',
    'lmstudio': 'https://lmstudio.ai/',
  };

  /// 官网链接（无则空字符串）
  String get officialUrl => _officialUrls[id] ?? '';

  static List<ApiProviderTemplate> byGroup(ApiProviderGroup g) =>
      all.where((e) => e.group == g).toList();

  String get recommendedModelId => models.isNotEmpty
      ? models.firstWhere((m) => m.recommended, orElse: () => models.first).id
      : defaultModel;
}

enum ApiProviderGroup {
  domestic, // 国内
  international, // 国际
  local, // 本地模型
}

// =====================================================================
// 20 个模板 + 自定义：按使用频率从高到低排序
// 免费标记规则（超级严格）：
//   ✅ hasFreeTier=true  → 提供「永久可循环用」的免费 API 层/模型
//                         （不限总量用完作废、不一次性、不过期）
//   ❌ hasFreeTier=false → 其他情况：一次性赠金、限时代金券、
//                          API 全付费但网页端免费、欢迎额度用完就没
// =====================================================================
const _all = <ApiProviderTemplate>[
  // ================================================================
  // 国内组（按 OpenRouter 全球 Token 量 + 国内社区口碑排序）
  // ================================================================

  // ① DeepSeek —— 全球#3调用量，V4系列2026主推
  ApiProviderTemplate(
    id: 'deepseek',
    nameZh: 'DeepSeek',
    nameEn: 'DeepSeek',
    defaultConfigName: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-v4-flash',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅新账号赠 500 万 Tokens（30天有效），过期/用完后 API 全付费',
    freeDetailEn: 'New-account 5M tokens (30 days only); API paid after credit expires',
    descZh: '2026 最新 V4 系列，V4-Flash 性价比极高，API 按量付费',
    descEn: 'Latest V4 lineup 2026; V4-Flash best cost/performance',
    color: Colors.purple,
    icon: Icons.all_inclusive,
    models: [
      ModelOption(id: 'deepseek-v4-flash', nameZh: 'V4-Flash · 性价比', nameEn: 'V4-Flash · Value', recommended: true, noteZh: '主力 1M 上下文，2026 主推', noteEn: '1M ctx, 2026 flagship value'),
      ModelOption(id: 'deepseek-v4-pro', nameZh: 'V4-Pro · 旗舰', nameEn: 'V4-Pro · Flagship', noteZh: '1M 上下文，更强推理', noteEn: '1M ctx, strongest reasoning'),
      ModelOption(id: 'deepseek-chat', nameZh: 'V3 · 兼容旧版', nameEn: 'V3 · Legacy', noteZh: '2026-07-24 已废弃', noteEn: 'Deprecated 2026-07-24'),
      ModelOption(id: 'deepseek-reasoner', nameZh: 'R1 · 推理旧版', nameEn: 'R1 · Legacy Reasoner', noteZh: '已迁移到 V4 思考模式', noteEn: 'Migrate to V4 thinking mode'),
    ],
  ),

  // ② 通义千问 Qwen —— 国内生态最广，3.7/3.8系列
  ApiProviderTemplate(
    id: 'dashscope',
    nameZh: '阿里云 百炼 (Qwen)',
    nameEn: 'DashScope (Qwen)',
    defaultConfigName: '阿里云·百炼',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen3.7-plus',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅新用户一次性赠 Tokens + 月度赠送额度，额度用完全付费',
    freeDetailEn: 'One-time welcome + monthly free quota; API paid after quota runs out',
    descZh: '国内首选，模型最全；Qwen3.7/3.8 长上下文 1M',
    descEn: 'Broadest model lineup in China; 1M context on 3.7/3.8',
    color: Colors.orange,
    icon: Icons.cloud,
    models: [
      ModelOption(id: 'qwen3.7-plus', nameZh: 'Qwen3.7-Plus · 均衡', nameEn: 'Qwen3.7-Plus · Balanced', recommended: true, noteZh: '1M 上下文，日常主力', noteEn: '1M ctx, daily workhorse'),
      ModelOption(id: 'qwen3.7-flash', nameZh: 'Qwen3.7-Flash · 极速', nameEn: 'Qwen3.7-Flash · Fast', noteZh: '便宜大量调用', noteEn: 'Cheap for bulk calls'),
      ModelOption(id: 'qwen3.8-max', nameZh: 'Qwen3.8-Max · 旗舰', nameEn: 'Qwen3.8-Max · Flagship', noteZh: '2026 最新旗舰，1M 上下文', noteEn: '2026 newest flagship, 1M ctx'),
      ModelOption(id: 'qwen3.7-max', nameZh: 'Qwen3.7-Max · 上一代旗舰', nameEn: 'Qwen3.7-Max · Prev Flagship', noteZh: '长期折扣中', noteEn: 'Running promo discount'),
      ModelOption(id: 'qwen-long', nameZh: 'Qwen-Long · 长文', nameEn: 'Qwen-Long', noteZh: '超长上下文', noteEn: 'Ultra-long context'),
      ModelOption(id: 'qwen-vl-max', nameZh: 'Qwen-VL-Max · 多模态', nameEn: 'Qwen-VL-Max · Vision', noteZh: '图片理解', noteEn: 'Image understanding'),
    ],
  ),

  // ③ 智谱 GLM —— 开源代码SOTA，4.7-Flash真正永久免费API
  ApiProviderTemplate(
    id: 'glm',
    nameZh: '智谱 GLM',
    nameEn: 'Zhipu GLM',
    defaultConfigName: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4.7-flash',
    group: ApiProviderGroup.domestic,
    hasFreeTier: true,
    freeDetailZh: 'GLM-4-Flash / GLM-4.7-Flash 永久免费；新用户赠 2000 万 Tokens',
    freeDetailEn: 'GLM-4/4.7-Flash FREE forever; new users get 20M tokens',
    descZh: 'Coding 能力开源 SOTA；4.7-Flash 永久免费 API',
    descEn: 'Open-source coding SOTA; 4.7-Flash free API forever',
    color: Colors.teal,
    icon: Icons.smart_toy,
    models: [
      ModelOption(id: 'glm-4.7-flash', nameZh: 'GLM-4.7-Flash · 永久免费', nameEn: 'GLM-4.7-Flash · Free Forever', isFreeModel: true, recommended: true, noteZh: '200K 上下文，免费', noteEn: '200K ctx, free'),
      ModelOption(id: 'glm-4-flash', nameZh: 'GLM-4-Flash · 永久免费', nameEn: 'GLM-4-Flash · Free Forever', isFreeModel: true, noteZh: '128K 上下文，免费', noteEn: '128K ctx, free'),
      ModelOption(id: 'glm-4.5-air', nameZh: 'GLM-4.5-Air · 高性价比', nameEn: 'GLM-4.5-Air · Value', noteZh: '¥0.8/¥2 每百万', noteEn: '¥0.8/¥2 per M'),
      ModelOption(id: 'glm-4.7', nameZh: 'GLM-4.7 · 主力', nameEn: 'GLM-4.7 · Mainstream', noteZh: '高智能主力档', noteEn: 'Balanced intelligence'),
      ModelOption(id: 'glm-5.2', nameZh: 'GLM-5.2 · 旗舰', nameEn: 'GLM-5.2 · Flagship', noteZh: '1M 上下文，Coding SOTA', noteEn: '1M ctx, coding SOTA'),
      ModelOption(id: 'glm-5.3', nameZh: 'GLM-5.3 · 最新旗舰', nameEn: 'GLM-5.3 · Newest Flagship', noteZh: '2026-08 最新发布', noteEn: 'Released Aug 2026'),
    ],
  ),

  // ④ Kimi Moonshot —— 全球#2调用量，256K/1M长上下文
  ApiProviderTemplate(
    id: 'kimi',
    nameZh: 'Kimi · 月之暗面',
    nameEn: 'Kimi (Moonshot)',
    defaultConfigName: 'Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'kimi-k2.5',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅新用户赠 15 元代金券（总量有限用完即止），API 按用量付费',
    freeDetailEn: 'New-account ~¥15 credit (finite, used up then paid); API pay-per-use',
    descZh: '256K/1M 超长上下文；编程 Agent 强',
    descEn: '256K/1M long context; strong coding agent',
    color: Colors.lightBlue,
    icon: Icons.dark_mode,
    models: [
      ModelOption(id: 'kimi-k2.5', nameZh: 'Kimi-K2.5 · 主力', nameEn: 'Kimi-K2.5 · Main', recommended: true, noteZh: '256K 上下文，多模态', noteEn: '256K ctx, multimodal'),
      ModelOption(id: 'kimi-k2.6', nameZh: 'Kimi-K2.6 · 高性能', nameEn: 'Kimi-K2.6 · Performance', noteZh: '延迟更低，393 tps', noteEn: 'Low latency, 393 tps'),
      ModelOption(id: 'kimi-k2.7-code', nameZh: 'Kimi-K2.7-Code · 编码', nameEn: 'Kimi-K2.7-Code', noteZh: '编程专项模型', noteEn: 'Coding specialized'),
      ModelOption(id: 'kimi-k3', nameZh: 'Kimi-K3 · 旗舰', nameEn: 'Kimi-K3 · Flagship', noteZh: '2026-07 发布，1M 上下文', noteEn: 'Released Jul 2026, 1M ctx'),
    ],
  ),

  // ⑤ 硅基流动 SiliconFlow —— 开源聚合，9B以下永久免费
  ApiProviderTemplate(
    id: 'siliconflow',
    nameZh: '硅基流动',
    nameEn: 'SiliconFlow',
    defaultConfigName: '硅基流动',
    baseUrl: 'https://api.siliconflow.cn/v1',
    defaultModel: 'deepseek-ai/DeepSeek-V4-Flash',
    group: ApiProviderGroup.domestic,
    hasFreeTier: true,
    freeDetailZh: '9B 以下开源模型永久免费；新用户赠 2000 万 Tokens',
    freeDetailEn: 'Models ≤9B FREE forever; new users get 20M tokens',
    descZh: '开源模型聚合平台；国内访问快',
    descEn: 'Open-source model hub; low latency in China',
    color: Colors.cyan,
    icon: Icons.lan,
    models: [
      ModelOption(id: 'deepseek-ai/DeepSeek-V4-Flash', nameZh: 'DeepSeek V4-Flash', nameEn: 'DeepSeek V4-Flash', recommended: true, noteZh: '最新 V4', noteEn: 'Latest V4'),
      ModelOption(id: 'Qwen/Qwen2.5-7B-Instruct', nameZh: 'Qwen2.5-7B · 永久免费', nameEn: 'Qwen2.5-7B · Free Forever', isFreeModel: true, noteZh: '≤9B 免费', noteEn: '≤9B, free'),
      ModelOption(id: 'Qwen/Qwen2.5-72B-Instruct', nameZh: 'Qwen2.5-72B', nameEn: 'Qwen2.5-72B'),
      ModelOption(id: 'THUDM/glm-4.7-flash', nameZh: 'GLM-4.7-Flash · 免费', nameEn: 'GLM-4.7-Flash · Free', isFreeModel: true),
      ModelOption(id: 'meta-llama/Llama-3.3-70B-Instruct', nameZh: 'Llama-3.3-70B', nameEn: 'Llama-3.3-70B'),
    ],
  ),

  // ⑥ MiniMax —— 全球#1调用量(M2.5/M3)
  ApiProviderTemplate(
    id: 'minimax',
    nameZh: 'MiniMax',
    nameEn: 'MiniMax',
    defaultConfigName: 'MiniMax',
    baseUrl: 'https://api.minimaxi.com/v1',
    defaultModel: 'MiniMax-M3',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: 'API 全付费；仅网页端个人免费',
    freeDetailEn: 'API is paid; only web chat is free for individuals',
    descZh: '全球 Token 量最大(M2.5/M3)；多模态强',
    descEn: 'Highest global token volume; strong multimodal',
    color: Colors.indigo,
    icon: Icons.animation,
    models: [
      ModelOption(id: 'MiniMax-M3', nameZh: 'MiniMax-M3 · 最新旗舰', nameEn: 'MiniMax-M3 · Newest', recommended: true, noteZh: '2026 最新', noteEn: '2026 latest'),
      ModelOption(id: 'MiniMax-M2.5', nameZh: 'MiniMax-M2.5', nameEn: 'MiniMax-M2.5', noteZh: '全球周调用量第一', noteEn: 'Global #1 weekly tokens'),
      ModelOption(id: 'MiniMax-Text-01', nameZh: 'MiniMax-Text-01', nameEn: 'MiniMax-Text-01'),
    ],
  ),

  // ⑦ 豆包 火山引擎 —— Seed 2.0 Pro 综合能力强
  ApiProviderTemplate(
    id: 'doubao',
    nameZh: '豆包 · 火山引擎',
    nameEn: 'Doubao (VolcEngine)',
    defaultConfigName: '豆包 (火山)',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    defaultModel: 'doubao-seed-2-pro-32k',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅有"安心体验"一次性额度 + 协作活动奖励，用完即止，API 非永久免费',
    freeDetailEn: 'Safe-mode one-time quota + activity rewards only; non-permanent free API',
    descZh: 'Seed-2.0 Pro 中文综合体验最佳；支持所有主流模型',
    descEn: 'Best Chinese chat experience; supports all major models',
    color: Colors.red,
    icon: Icons.volcano,
    models: [
      ModelOption(id: 'doubao-seed-2-pro-32k', nameZh: 'Seed 2.0 Pro · 32K', nameEn: 'Seed 2.0 Pro · 32K', recommended: true, noteZh: '中文综合第一', noteEn: 'Best Chinese overall'),
      ModelOption(id: 'doubao-seed-2-lite-32k', nameZh: 'Seed 2.0 Lite', nameEn: 'Seed 2.0 Lite', noteZh: '轻量便宜', noteEn: 'Light & cheap'),
      ModelOption(id: 'doubao-1-5-pro-32k', nameZh: '豆包 1.5 Pro · 32K', nameEn: 'Doubao 1.5 Pro · 32K'),
      ModelOption(id: 'doubao-1-5-lite-32k', nameZh: '豆包 1.5 Lite', nameEn: 'Doubao 1.5 Lite'),
    ],
  ),

  // ⑧ 百度千帆 —— ERNIE-Speed永久免费
  ApiProviderTemplate(
    id: 'qianfan',
    nameZh: '百度 千帆 (ERNIE)',
    nameEn: 'Baidu Qianfan (ERNIE)',
    defaultConfigName: '百度千帆',
    baseUrl: 'https://qianfan.baidubce.com/v2',
    defaultModel: 'ernie_speed_8k',
    group: ApiProviderGroup.domestic,
    hasFreeTier: true,
    freeDetailZh: 'ERNIE-Speed-8K / ERNIE-3.5-8K 永久免费，QPS 50',
    freeDetailEn: 'ERNIE-Speed-8K / ERNIE-3.5-8K free forever, QPS 50',
    descZh: '百度出品；ERNIE-Speed 永久免费不限量',
    descEn: 'Baidu; ERNIE-Speed free forever unlimited',
    color: Colors.blueGrey,
    icon: Icons.public,
    models: [
      ModelOption(id: 'ernie_speed_8k', nameZh: 'ERNIE-Speed-8K · 永久免费', nameEn: 'ERNIE-Speed-8K · Free Forever', isFreeModel: true, recommended: true, noteZh: '永久免费，QPS 50', noteEn: 'Free forever, QPS 50'),
      ModelOption(id: 'ernie-3.5-8k', nameZh: 'ERNIE-3.5-8K · 永久免费', nameEn: 'ERNIE-3.5-8K · Free Forever', isFreeModel: true, noteZh: '永久免费', noteEn: 'Free forever'),
      ModelOption(id: 'ernie-4.5-turbo-vl-preview', nameZh: 'ERNIE-4.5 · 旗舰', nameEn: 'ERNIE-4.5 · Flagship', noteZh: '多模态', noteEn: 'Multimodal'),
      ModelOption(id: 'ernie-tiny-8k', nameZh: 'ERNIE-Tiny · 极速', nameEn: 'ERNIE-Tiny · Fastest', noteZh: '最快最轻', noteEn: 'Fastest, lightest'),
    ],
  ),

  // ⑨ 腾讯混元
  ApiProviderTemplate(
    id: 'hunyuan',
    nameZh: '腾讯 混元',
    nameEn: 'Tencent Hunyuan',
    defaultConfigName: '腾讯混元',
    baseUrl: 'https://api.hunyuan.tencent.com/v1',
    defaultModel: 'hunyuan-standard',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅新用户一次性 100 万 Token 资源包，用完即止，API 全付费',
    freeDetailEn: 'New-user one-time 1M token package only; API fully paid afterward',
    descZh: '腾讯官方；微信/腾讯生态集成',
    descEn: 'Tencent official; WeChat/Tencent ecosystem',
    color: const Color(0xFF20B2AA),
    icon: Icons.brightness_auto,
    models: [
      ModelOption(id: 'hunyuan-standard', nameZh: '混元-Standard · 均衡', nameEn: 'Hunyuan-Standard', recommended: true),
      ModelOption(id: 'hunyuan-large', nameZh: '混元-Large · 旗舰', nameEn: 'Hunyuan-Large · Flagship'),
      ModelOption(id: 'hunyuan-lite', nameZh: '混元-Lite · 轻量', nameEn: 'Hunyuan-Lite · Light'),
      ModelOption(id: 'hunyuan-code', nameZh: '混元-Code · 编码', nameEn: 'Hunyuan-Code'),
    ],
  ),

  // ⑩ 讯飞星火
  ApiProviderTemplate(
    id: 'xfyun',
    nameZh: '讯飞 星火',
    nameEn: 'XFYun Spark',
    defaultConfigName: '讯飞星火',
    baseUrl: 'https://spark-openapi.cn-huabei-1.xf-yun.com/v1',
    defaultModel: 'spark-lite',
    group: ApiProviderGroup.domestic,
    hasFreeTier: true,
    freeDetailZh: 'Spark-Lite 永久免费（总量不限，QPS 2）',
    freeDetailEn: 'Spark-Lite free forever (unlimited tokens, QPS 2)',
    descZh: '中文理解强；Spark-Lite 永久免费',
    descEn: 'Strong Chinese understanding; Spark-Lite free forever',
    color: const Color(0xFF1E90FF),
    icon: Icons.local_fire_department,
    models: [
      ModelOption(id: 'spark-lite', nameZh: 'Spark-Lite · 永久免费', nameEn: 'Spark-Lite · Free Forever', isFreeModel: true, recommended: true, noteZh: '永久免费，QPS 2', noteEn: 'Free forever, QPS 2'),
      ModelOption(id: 'spark-pro', nameZh: 'Spark-Pro · 主力', nameEn: 'Spark-Pro · Main'),
      ModelOption(id: 'spark-max', nameZh: 'Spark-Max · 旗舰', nameEn: 'Spark-Max · Flagship'),
      ModelOption(id: 'spark-ultra', nameZh: 'Spark-Ultra · 最强', nameEn: 'Spark-Ultra · Strongest'),
    ],
  ),

  // ================================================================
  // 国际组（按全球开发者使用频率排序）
  // ================================================================

  // ⑪ OpenRouter —— 一把 Key 用 400+ 模型
  ApiProviderTemplate(
    id: 'openrouter',
    nameZh: 'OpenRouter (400+ 模型)',
    nameEn: 'OpenRouter (400+ Models)',
    defaultConfigName: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openrouter/auto',
    group: ApiProviderGroup.international,
    hasFreeTier: false,
    freeDetailZh: '仅部分模型偶有免费促销；平台本身无稳定永久免费层',
    freeDetailEn: 'Occasional free-tier model promos only; no stable permanent free tier on platform',
    descZh: '一把 Key 访问全球所有主流大模型',
    descEn: 'One API key for 400+ models worldwide',
    color: Colors.amber,
    icon: Icons.hub,
    models: [
      ModelOption(id: 'openrouter/auto', nameZh: 'Auto · 自动路由', nameEn: 'Auto · Auto Route', recommended: true, noteZh: '自动选最便宜', noteEn: 'Auto cheapest'),
      ModelOption(id: 'deepseek/deepseek-v4-flash', nameZh: 'DeepSeek V4-Flash', nameEn: 'DeepSeek V4-Flash'),
      ModelOption(id: 'anthropic/claude-sonnet-4.6', nameZh: 'Claude Sonnet 4.6', nameEn: 'Claude Sonnet 4.6'),
      ModelOption(id: 'google/gemini-3-flash', nameZh: 'Gemini 3 Flash', nameEn: 'Gemini 3 Flash'),
      ModelOption(id: 'openai/gpt-5.4-mini', nameZh: 'GPT-5.4 Mini', nameEn: 'GPT-5.4 Mini'),
    ],
  ),

  // ⑫ OpenAI —— 行业标杆
  ApiProviderTemplate(
    id: 'openai',
    nameZh: 'OpenAI (GPT)',
    nameEn: 'OpenAI (GPT)',
    defaultConfigName: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-5.4-mini',
    group: ApiProviderGroup.international,
    hasFreeTier: false,
    freeDetailZh: 'API 全付费；无免费额度（需绑卡）',
    freeDetailEn: 'API fully paid; no free tier (credit card required)',
    descZh: 'GPT-5.5 / 5.4 系列；Agent 能力突破基线',
    descEn: 'GPT-5.5 / 5.4; agent capability beat human baseline',
    color: Colors.green,
    icon: Icons.generating_tokens,
    models: [
      ModelOption(id: 'gpt-5.4-mini', nameZh: 'GPT-5.4 Mini · 轻量', nameEn: 'GPT-5.4 Mini · Light', recommended: true, noteZh: '便宜快', noteEn: 'Cheap & fast'),
      ModelOption(id: 'gpt-5.4', nameZh: 'GPT-5.4 · 旗舰', nameEn: 'GPT-5.4 · Flagship', noteZh: '多模态', noteEn: 'Multimodal'),
      ModelOption(id: 'gpt-5.5', nameZh: 'GPT-5.5 · 最新旗舰', nameEn: 'GPT-5.5 · Newest Flagship', noteZh: '2026 最新', noteEn: '2026 newest'),
      ModelOption(id: 'o3-mini', nameZh: 'o3-mini · 推理', nameEn: 'o3-mini · Reasoner', noteZh: '链式思考', noteEn: 'Chain-of-thought'),
    ],
  ),

  // ⑬ Google Gemini —— Gemini 3 系列
  ApiProviderTemplate(
    id: 'gemini',
    nameZh: 'Google Gemini',
    nameEn: 'Google Gemini',
    defaultConfigName: 'Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    defaultModel: 'gemini-3-flash',
    group: ApiProviderGroup.international,
    hasFreeTier: true,
    freeDetailZh: 'Gemini 3 Flash / 2.5 Flash 免费层（限 RPM/RPD）',
    freeDetailEn: 'Gemini 3/2.5 Flash free tier (RPM/RPD limits)',
    descZh: 'Gemini 3 系列；多模态标杆',
    descEn: 'Gemini 3 lineup; multimodal benchmark leader',
    color: Colors.blueAccent,
    icon: Icons.auto_awesome,
    models: [
      ModelOption(id: 'gemini-3-flash', nameZh: 'Gemini 3 Flash · 免费层', nameEn: 'Gemini 3 Flash · Free Tier', isFreeModel: true, recommended: true, noteZh: '免费层可用', noteEn: 'Free tier'),
      ModelOption(id: 'gemini-3.5-flash', nameZh: 'Gemini 3.5 Flash', nameEn: 'Gemini 3.5 Flash'),
      ModelOption(id: 'gemini-3.1-pro', nameZh: 'Gemini 3.1 Pro · 旗舰', nameEn: 'Gemini 3.1 Pro · Flagship', noteZh: '16项基准赢13项', noteEn: 'Won 13/16 benchmarks'),
      ModelOption(id: 'gemini-2.5-flash', nameZh: 'Gemini 2.5 Flash · 免费', nameEn: 'Gemini 2.5 Flash · Free', isFreeModel: true),
    ],
  ),

  // ⑭ Groq —— LPU 极速推理
  ApiProviderTemplate(
    id: 'groq',
    nameZh: 'Groq (极速推理)',
    nameEn: 'Groq (Ultra Fast)',
    defaultConfigName: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    defaultModel: 'llama-3.3-70b-versatile',
    group: ApiProviderGroup.international,
    hasFreeTier: true,
    freeDetailZh: '免费层：RPM 30、RPD 14400、TPD 500K',
    freeDetailEn: 'Free tier: 30 RPM, 14,400 RPD, 500K TPD',
    descZh: 'LPU 加速；推理 <100ms 响应',
    descEn: 'LPU-accelerated; sub-100ms inference',
    color: Colors.deepOrange,
    icon: Icons.bolt,
    models: [
      ModelOption(id: 'llama-3.3-70b-versatile', nameZh: 'Llama-3.3-70B', nameEn: 'Llama-3.3-70B', recommended: true),
      ModelOption(id: 'llama-3.1-8b-instant', nameZh: 'Llama-3.1-8B · 极速', nameEn: 'Llama-3.1-8B · Instant', noteZh: '最快', noteEn: 'Fastest'),
      ModelOption(id: 'qwen/qwen3-32b', nameZh: 'Qwen3-32B', nameEn: 'Qwen3-32B'),
    ],
  ),

  // ⑮ Anthropic Claude (兼容接口)
  ApiProviderTemplate(
    id: 'claude',
    nameZh: 'Anthropic Claude',
    nameEn: 'Anthropic Claude',
    defaultConfigName: 'Claude',
    baseUrl: 'https://api.anthropic.com/v1',
    defaultModel: 'claude-sonnet-4.6',
    group: ApiProviderGroup.international,
    hasFreeTier: false,
    freeDetailZh: 'API 全付费；无免费额度',
    freeDetailEn: 'API fully paid; no free tier',
    descZh: '综合体验最佳（Claude Opus）；编程 SWE-bench 80.8%',
    descEn: 'Best overall experience; 80.8% on SWE-bench',
    color: Colors.brown,
    icon: Icons.wb_sunny,
    models: [
      ModelOption(id: 'claude-sonnet-4.6', nameZh: 'Claude Sonnet 4.6 · 均衡', nameEn: 'Claude Sonnet 4.6 · Balanced', recommended: true, noteZh: '性价比', noteEn: 'Good value'),
      ModelOption(id: 'claude-haiku-4.5', nameZh: 'Claude Haiku 4.5 · 极速', nameEn: 'Claude Haiku 4.5 · Fast', noteZh: '最快最便宜', noteEn: 'Fastest & cheapest'),
      ModelOption(id: 'claude-opus-4.6', nameZh: 'Claude Opus 4.6 · 旗舰', nameEn: 'Claude Opus 4.6 · Flagship', noteZh: '综合体验第一', noteEn: 'Best overall LMArena #1'),
      ModelOption(id: 'claude-opus-5', nameZh: 'Claude Opus 5 · 最新旗舰', nameEn: 'Claude Opus 5 · Newest', noteZh: '2026 最新', noteEn: '2026 newest'),
    ],
  ),

  // ⑯ Together AI
  ApiProviderTemplate(
    id: 'together',
    nameZh: 'Together AI',
    nameEn: 'Together AI',
    defaultConfigName: 'Together AI',
    baseUrl: 'https://api.together.xyz/v1',
    defaultModel: 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
    group: ApiProviderGroup.international,
    hasFreeTier: false,
    freeDetailZh: 'API 全付费；新账户限时赠金',
    freeDetailEn: 'API paid; new-account time-limited credit',
    descZh: '开源模型推理云；性价比',
    descEn: 'Open source model cloud inference',
    color: Colors.pinkAccent,
    icon: Icons.account_tree,
    models: [
      ModelOption(id: 'meta-llama/Llama-3.3-70B-Instruct-Turbo', nameZh: 'Llama-3.3-70B Turbo', nameEn: 'Llama-3.3-70B Turbo', recommended: true),
      ModelOption(id: 'deepseek-ai/DeepSeek-V4-Pro', nameZh: 'DeepSeek V4-Pro', nameEn: 'DeepSeek V4-Pro', noteZh: '1.6T MoE', noteEn: '1.6T MoE'),
      ModelOption(id: 'meta-llama/Llama-4-Ultra', nameZh: 'Llama-4-Ultra', nameEn: 'Llama-4-Ultra', noteZh: 'Meta 最新旗舰', noteEn: 'Meta newest flagship'),
    ],
  ),

  // ================================================================
  // 本地模型组（模型实际运行在电脑上，完全免费，无需 API Key）
  // 适配：电脑本地运行的量化模型；手机只是客户端，通过局域网连接
  // ================================================================

  // ⑰ Ollama 本地模型（模型跑在电脑上，手机通过局域网连接）
  // v1.3.9：baseUrl 默认留空，避免误用 localhost（手机上 localhost 指手机本身，
  //   永远连不到电脑的 Ollama 服务）。用户需手动填电脑局域网 IP，如 http://192.168.1.100:11434/v1
  ApiProviderTemplate(
    id: 'ollama',
    nameZh: 'Ollama (本地模型)',
    nameEn: 'Ollama (Local Models)',
    defaultConfigName: 'Ollama 本地',
    baseUrl: '',
    defaultModel: 'qwen2.5:3b-instruct-q4_K_M',
    group: ApiProviderGroup.local,
    hasFreeTier: true,
    freeDetailZh: '完全免费，本地运行，无需 API Key',
    freeDetailEn: '100% free, runs locally, no API Key',
    descZh: '模型实际跑在电脑上，手机只是客户端。⚠️ 手机端必须填电脑局域网 IP（如 http://192.168.1.100:11434/v1），不能用 localhost（localhost 在手机上指手机本身，连不到电脑的 Ollama）',
    descEn: 'Models actually run on your PC; phone is just the client. ⚠️ On phone you MUST use PC LAN IP (e.g. http://192.168.1.100:11434/v1), NOT localhost (localhost on phone means the phone itself, cannot reach PC Ollama)',
    color: Colors.black87,
    icon: Icons.computer,
    models: [
      // —— 电脑轻量（低配电脑也能跑）——
      ModelOption(id: 'qwen2.5:0.5b-instruct-q4_0', nameZh: 'Qwen2.5-0.5B · 电脑轻量', nameEn: 'Qwen2.5-0.5B · PC Light', isFreeModel: true, noteZh: '~400MB，电脑低配流畅', noteEn: '~400MB, smooth on low-end PC'),
      ModelOption(id: 'qwen2.5:1.5b-instruct-q4_0', nameZh: 'Qwen2.5-1.5B · 电脑主力', nameEn: 'Qwen2.5-1.5B · PC Main', isFreeModel: true, recommended: true, noteZh: '~1GB，电脑对话主力', noteEn: '~1GB, main for PC chat'),
      ModelOption(id: 'minicpm3-v2_5:2b-instruct-q4_K_M', nameZh: 'MiniCPM3-2B · 中文强', nameEn: 'MiniCPM3-2B · Good Chinese', isFreeModel: true, noteZh: '中文能力强，~1.4GB', noteEn: 'Strong Chinese, ~1.4GB'),
      ModelOption(id: 'llama3.2:1b-instruct-q4_0', nameZh: 'Llama3.2-1B', nameEn: 'Llama3.2-1B', isFreeModel: true, noteZh: '~730MB', noteEn: '~730MB'),
      ModelOption(id: 'qwen2.5:3b-instruct-q4_K_M', nameZh: 'Qwen2.5-3B · 电脑进阶', nameEn: 'Qwen2.5-3B · PC Advanced', isFreeModel: true, noteZh: '~2GB，电脑进阶首选', noteEn: '~2GB, PC advanced pick'),
      ModelOption(id: 'llama3.2:3b-instruct-q4_0', nameZh: 'Llama3.2-3B', nameEn: 'Llama3.2-3B', isFreeModel: true, noteZh: '~1.8GB，电脑进阶', noteEn: '~1.8GB, PC advanced'),
      // —— 桌面级（需较好电脑配置，8GB+ VRAM / 大内存）——
      ModelOption(id: 'qwen2.5:7b-instruct-q4_K_M', nameZh: 'Qwen2.5-7B · 桌面级', nameEn: 'Qwen2.5-7B · Desktop', isFreeModel: true, noteZh: '桌面 / 高配电脑', noteEn: 'Desktop / high-end PC'),
      ModelOption(id: 'gemma3:4b-instruct-q4_K_M', nameZh: 'Gemma3-4B', nameEn: 'Gemma3-4B', isFreeModel: true),
      ModelOption(id: 'phi3:mini-4k-instruct', nameZh: 'Phi-3-Mini', nameEn: 'Phi-3-Mini', isFreeModel: true, noteZh: '~2.3GB', noteEn: '~2.3GB'),
    ],
  ),

  // ⑱ LM Studio（桌面端 GUI 本地模型）
  // v1.3.9：baseUrl 默认留空（同 Ollama），避免误用 localhost
  ApiProviderTemplate(
    id: 'lmstudio',
    nameZh: 'LM Studio (桌面本地)',
    nameEn: 'LM Studio (Desktop Local)',
    defaultConfigName: 'LM Studio 本地',
    baseUrl: '',
    defaultModel: 'local-model',
    group: ApiProviderGroup.local,
    hasFreeTier: true,
    freeDetailZh: '完全免费，桌面端使用，无需 API Key',
    freeDetailEn: '100% free for desktop; no API Key',
    descZh: '电脑端本地模型 GUI；推荐 GGUF 量化模型。⚠️ 手机端必须填电脑局域网 IP（如 http://192.168.1.100:1234/v1），不能用 localhost',
    descEn: 'Desktop local model GUI; GGUF quantized recommended. ⚠️ On phone use PC LAN IP (e.g. http://192.168.1.100:1234/v1), NOT localhost',
    color: Colors.brown,
    icon: Icons.desktop_mac,
    models: [
      ModelOption(id: 'bartowski/Qwen2.5-14B-Instruct-GGUF/qwen2.5-14b-instruct.Q4_K_M.gguf', nameZh: 'Qwen2.5-14B · 桌面推荐', nameEn: 'Qwen2.5-14B · Desktop Rec', recommended: true, isFreeModel: true),
      ModelOption(id: 'lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf', nameZh: 'Llama3.1-8B', nameEn: 'Llama3.1-8B', isFreeModel: true),
    ],
  ),
];
