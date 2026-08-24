import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../models/api_provider_template.dart';
import '../services/storage_service.dart';
import '../services/api_service.dart';
import '../services/logger_service.dart';

class ApiConfigEditScreen extends StatefulWidget {
  final ApiConfig? config;

  const ApiConfigEditScreen({super.key, this.config});

  @override
  State<ApiConfigEditScreen> createState() => _ApiConfigEditScreenState();
}

class _ApiConfigEditScreenState extends State<ApiConfigEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _baseUrlController;
  late TextEditingController _apiKeyController;
  late TextEditingController _modelController;
  late TextEditingController _systemPromptController;
  late double _temperature;
  late int _maxTokens;
  bool _isTesting = false;
  String _testResult = '';
  bool _testSuccess = false;
  String _selectedTemplateId = ApiProviderTemplate.customId;
  // 当前选中的模型 id（仅用于高亮 UI；真正落到 config 的是 _modelController.text）
  String _selectedModelId = '';

  // v1.5.0：动态拉取模型列表
  bool _isRefreshingModels = false;
  String _refreshModelsMsg = '';
  List<String> _cachedModels = const [];
  String? _lastRefreshedAt;

  /// v1.5.3：按 baseUrl 缓存模型列表，切模板时恢复对应服务商的模型，
  /// 不串台（DeepSeek 模型不会串到阿里云）、不丢失（切回 DeepSeek 还在）。
  /// key = baseUrl，value = 该服务商拉取到的模型 id 列表。
  final Map<String, List<String>> _modelsByUrl = {};

  /// v1.5.4：按 baseUrl 分桶缓存 API Key，每个服务商独立保存自己的 Key。
  /// 切模板时自动切换对应服务商的 Key（DeepSeek 的 Key 不会串到阿里云，切回 DeepSeek 还在）。
  /// key = baseUrl，value = 该服务商的 API Key。
  final Map<String, String> _apiKeysByUrl = {};

  @override
  void initState() {
    super.initState();
    final c = widget.config ?? ApiConfig.create();
    _nameController = TextEditingController(text: c.name);
    _baseUrlController = TextEditingController(text: c.baseUrl);
    _apiKeyController = TextEditingController(text: c.apiKey);
    _modelController = TextEditingController(text: c.model);
    _systemPromptController = TextEditingController(text: c.systemPrompt);
    _temperature = c.temperature;
    _maxTokens = c.maxTokens;
    // v1.5.0：从 ApiConfig 加载已缓存的模型列表（用户上次拉的）
    _cachedModels = c.cachedModelsList;
    // v1.5.3：把当前配置的 cachedModels 按 baseUrl 存入缓存 Map（编辑已有配置时）
    if (c.cachedModelsList.isNotEmpty && c.baseUrl.trim().isNotEmpty) {
      _modelsByUrl[c.baseUrl.trim()] = c.cachedModelsList;
    }
    // v1.5.4：把当前配置的 API Key 按 baseUrl 存入缓存 Map（编辑已有配置时）
    if (c.apiKey.isNotEmpty && c.baseUrl.trim().isNotEmpty) {
      _apiKeysByUrl[c.baseUrl.trim()] = c.apiKey;
    }
    // 如果是编辑现有配置，看看能不能反向匹配到模板
    _guessTemplateFromExisting();
  }

  /// v1.5.0：调 ApiService.listModels 拉取真实可用模型列表
  ///
  /// 参考实现：Chatbox 的 `OpenAICompatible.listModels()`
  /// 调 `GET {baseUrl}/v1/models`，解析 `data[].id` 列表。
  ///
  /// 失败处理：保留旧 _cachedModels 不覆盖，UI 显示「拉取失败，已用上次缓存的列表」。
  /// 成功处理：缓存到 _cachedModels + 写回 ApiConfig.cachedModels（点保存时落库）。
  Future<void> _refreshModels() async {
    final isZh =
        AppLocalizations.of(context).locale.languageCode == 'zh';
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _refreshModelsMsg =
          isZh ? '⚠️ 请先填 Base URL' : '⚠️ Fill Base URL first');
      return;
    }
    setState(() {
      _isRefreshingModels = true;
      _refreshModelsMsg = '';
    });
    final logger = context.read<LoggerService>();
    try {
      final apiSvc = ApiService();
      final tmpCfg = ApiConfig(
        id: widget.config?.id ?? 'tmp',
        name: _nameController.text.trim(),
        baseUrl: baseUrl,
        apiKey: _apiKeyController.text.trim(),
        model: _modelController.text.trim(),
      );
      final models = await apiSvc.listModels(tmpCfg);
      // v1.5.3：异步回来后页面可能已销毁（用户退出），必须检查 mounted
      if (!mounted) return;
      if (models.isEmpty) {
        setState(() {
          _isRefreshingModels = false;
          _refreshModelsMsg =
              isZh ? '⚠️ 接口返回 0 个模型' : '⚠️ API returned 0 models';
        });
        return;
      }
      // 成功
      final now = DateTime.now();
      _lastRefreshedAt =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      logger.info(
          '[Config] Models refreshed: ${models.length} from $baseUrl',
          cat: LogCat.api,
          tag: 'Config');
      setState(() {
        _cachedModels = models;
        // v1.5.3：按 baseUrl 缓存，切模板时恢复、不串台
        _modelsByUrl[baseUrl] = models;
        _isRefreshingModels = false;
        _refreshModelsMsg = isZh
            ? '✅ 找到 ${models.length} 个模型'
                '${_lastRefreshedAt != null ? '（$_lastRefreshedAt）' : ''}'
            : '✅ Found ${models.length} models'
                '${_lastRefreshedAt != null ? ' ($_lastRefreshedAt)' : ''}';
      });
    } catch (e) {
      logger.warn('[Config] Refresh models failed: $e', tag: 'Config');
      // v1.5.3：异步回来后页面可能已销毁，必须检查 mounted（修 666.txt 崩溃）
      if (!mounted) return;
      setState(() {
        _isRefreshingModels = false;
        final errStr = e.toString();
        // v1.5.3：401 给明确提示（通常是 Key 没填/无效，不是 URL 问题）
        if (errStr.contains('401')) {
          _refreshModelsMsg = _cachedModels.isEmpty
              ? (isZh
                  ? '❌ 拉取失败：401 未授权，请先填写正确的 API Key'
                  : '❌ Failed: 401 unauthorized. Check your API key')
              : (isZh
                  ? '⚠️ 401 未授权（请检查 API Key），已用上次缓存的 ${_cachedModels.length} 个模型'
                  : '⚠️ 401 unauthorized (check API key), using ${_cachedModels.length} cached models');
        } else {
          _refreshModelsMsg = _cachedModels.isEmpty
              ? (isZh ? '❌ 拉取失败：$e' : '❌ Failed: $e')
              : (isZh
                  ? '⚠️ 拉取失败（$e），已用上次缓存的 ${_cachedModels.length} 个模型'
                  : '⚠️ Failed ($e), using ${_cachedModels.length} cached models');
        }
      });
    }
  }

  /// 编辑已有配置时，根据 baseUrl 尝试匹配到模板（让 UI 显示对应模型列表）
  void _guessTemplateFromExisting() {
    final url = _baseUrlController.text.trim();
    if (url.isEmpty) return;
    for (final t in ApiProviderTemplate.all) {
      if (url.contains(t.baseUrl.replaceAll('https://', '').replaceAll('http://', '').split('/').first) ||
          t.baseUrl.contains(url.replaceAll('https://', '').replaceAll('http://', '').split('/').first)) {
        _selectedTemplateId = t.id;
        _selectedModelId = _modelController.text.trim();
        return;
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final storage = context.read<StorageService>();
    final logger = context.read<LoggerService>();
    // v1.5.4：保存前把当前 Key 同步到分桶 Map（确保切走再切回能恢复）
    final curBaseUrl = _baseUrlController.text.trim();
    if (curBaseUrl.isNotEmpty) {
      _apiKeysByUrl[curBaseUrl] = _apiKeyController.text.trim();
    }
    // v1.5.0：cachedModels 序列化成 JSON 字符串一起落库（空列表→空字符串）
    final cachedJson = _cachedModels.isEmpty ? '' : json.encode(_cachedModels);
    final config = (widget.config ?? ApiConfig.create()).copyWith(
      name: _nameController.text.trim(),
      baseUrl: curBaseUrl,
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
      systemPrompt: _systemPromptController.text.trim(),
      temperature: _temperature,
      maxTokens: _maxTokens,
      cachedModels: cachedJson,
    );
    logger.info('Saving API config: name="${config.name}" model="${config.model}" baseUrl="${config.baseUrl}" cachedModels=${_cachedModels.length}项', tag: 'ApiConfig');
    await storage.saveApiConfig(config);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _testConnection() async {
    final l = AppLocalizations.of(context);
    final logger = context.read<LoggerService>();
    setState(() {
      _isTesting = true;
      _testResult = '';
    });
    try {
      final config = ApiConfig(
        id: widget.config?.id ?? '',
        name: _nameController.text,
        baseUrl: _baseUrlController.text.trim(),
        apiKey: _apiKeyController.text.trim(),
        model: _modelController.text.trim(),
      );
      logger.info('Testing connection → baseUrl=${config.baseUrl} model=${config.model}', tag: 'ApiTest');
      final t0 = DateTime.now();
      final result = await context.read<ApiService>().testConnection(config);
      final ms = DateTime.now().difference(t0).inMilliseconds;
      logger.info('Test OK (${ms}ms): ${result.length > 80 ? result.substring(0, 80) : result}', tag: 'ApiTest');
      // v1.6.8 修复 Bug#15：await 后 setState 必须检查 mounted（同文件 _refreshModels 已做，
      // _testConnection 三处漏检：try 成功 / catch 失败 / finally 重置）
      if (!mounted) return;
      setState(() {
        _testResult = '${l.tr('connectionOk')} (${ms}ms)';
        _testSuccess = true;
      });
    } catch (e, st) {
      logger.error('Test connection failed', error: e, stack: st, tag: 'ApiTest');
      if (!mounted) return;
      setState(() {
        _testResult = '${l.tr('connectionFailed')} : $e';
        _testSuccess = false;
      });
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  /// 选择服务商模板
  /// v1.5.4 变更：API Key 按 baseUrl 分桶缓存（DeepSeek Key / 阿里云 Key 各自独立）。
  /// 切换前先把当前 Key 存回旧服务商桶，切换后恢复新服务商的 Key（没有就空）。
  /// 模型列表同样按 baseUrl 恢复。
  Future<void> _applyTemplate(ApiProviderTemplate? t) async {
    if (t == null) {
      // Custom — 不覆盖用户输入
      setState(() => _selectedTemplateId = ApiProviderTemplate.customId);
      return;
    }
    setState(() {
      // 切换前：把当前填的 Key 存回旧服务商桶（防止 DeepSeek Key 串到阿里云）
      final oldBaseUrl = _baseUrlController.text.trim();
      if (oldBaseUrl.isNotEmpty) {
        _apiKeysByUrl[oldBaseUrl] = _apiKeyController.text;
      }

      _selectedTemplateId = t.id;
      // 名称/Base URL/Model 都从模板来（每次切换都覆盖，避免残留上一个模板的 model id）
      _nameController.text = t.defaultConfigName;
      _baseUrlController.text = t.baseUrl;
      final recId = t.recommendedModelId;
      _modelController.text = recId;
      _selectedModelId = recId;
      // v1.5.4：恢复新服务商的 Key（没有就空），每个服务商 Key 独立
      _apiKeyController.text = _apiKeysByUrl[t.baseUrl] ?? '';
      // v1.5.3：从缓存 Map 恢复该服务商的模型列表（不串台、不丢失）。
      // baseUrl 为空（本地模型 Ollama/LM Studio）时返回空列表，等用户填 IP 再刷新。
      _cachedModels = _modelsByUrl[t.baseUrl] ?? const [];
      _refreshModelsMsg = '';
    });
  }

  /// v1.5.2：已删除。原来切换服务商前弹窗问"保留还是清空 Key"，
  /// 用户反馈"不要每次切换"，改为强制保留 Key（不清空、不弹窗）。
  /// 保留此方法会造成 unused 警告，故一并删除。

  /// 在模板内切换模型版本
  void _selectModel(ModelOption m) {
    setState(() {
      _selectedModelId = m.id;
      _modelController.text = m.id;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.config == null
            ? l.tr('addApiConfig')
            : l.tr('editApiConfig')),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ================ Template Selector ================
            Text(l.tr('selectTemplate'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(l.tr('selectTemplateSubtitle'),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ..._buildGroupChips(isZh),
            const SizedBox(height: 4),
            if (_selectedTemplateId != ApiProviderTemplate.customId)
              _templateInfoHint(isZh),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),

            // ================ 模型版本切换器（选了非自定义模板才显示）================
            if (_selectedTemplateId != ApiProviderTemplate.customId) ...[
              _buildModelVersionSelector(isZh),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 16),
            ],

            // ================ Form Fields ================
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l.tr('configName'),
                hintText: 'OpenAI / DeepSeek',
                border: const OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.isEmpty) ? '*' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _baseUrlController,
              decoration: InputDecoration(
                labelText: l.tr('baseUrl'),
                hintText: 'https://api.openai.com/v1',
                helperText: (_selectedTemplateId == 'ollama' ||
                        _selectedTemplateId == 'lmstudio')
                    ? (isZh
                        ? '⚠️ 手机端请填电脑局域网 IP，如 http://192.168.1.100:11434/v1\n（不能用 localhost，localhost 在手机上指手机本身，连不到电脑的本地模型服务）'
                        : '⚠️ On phone use PC LAN IP, e.g. http://192.168.1.100:11434/v1\n(localhost on phone means phone itself, cannot reach PC local model)')
                    : null,
                border: const OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.isEmpty) ? '*' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _apiKeyController,
              decoration: InputDecoration(
                labelText: l.tr('apiKey'),
                hintText: 'sk-...',
                border: const OutlineInputBorder(),
                suffixIcon: _selectedTemplateId != ApiProviderTemplate.customId
                    ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
                    : null,
              ),
              obscureText: true,
              validator: (v) {
                // Local Ollama / LM Studio 可以不填 Key
                if (_selectedTemplateId == 'ollama' ||
                    _selectedTemplateId == 'lmstudio') {
                  return null;
                }
                return (v == null || v.isEmpty) ? '*' : null;
              },
            ),
            const SizedBox(height: 16),
            // v1.5.0：模型输入框 + 「🔄 刷新模型列表」按钮 + 下拉选择
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _modelController,
                    decoration: InputDecoration(
                      labelText: l.tr('model'),
                      hintText: 'gpt-4o-mini',
                      helperText: _selectedTemplateId != ApiProviderTemplate.customId
                          ? (isZh ? '已通过上方切换器填好，可手动覆盖' : 'Auto-filled by selector above; editable')
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.isEmpty) ? '*' : null,
                  ),
                ),
                const SizedBox(width: 8),
                // 「🔄 刷新模型列表」按钮（参考 Chatbox 的 listModels）
                FilledButton.tonalIcon(
                  onPressed: _isRefreshingModels ? null : _refreshModels,
                  icon: _isRefreshingModels
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: const Text('🔄'),
                ),
              ],
            ),
            // 刷新结果提示
            if (_refreshModelsMsg.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _refreshModelsMsg,
                style: TextStyle(
                  fontSize: 12,
                  color: _refreshModelsMsg.startsWith('✅')
                      ? Colors.green
                      : (_refreshModelsMsg.startsWith('⚠️') || _refreshModelsMsg.startsWith('❌')
                          ? Colors.orange
                          : Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ],
            // v1.5.1：动态拉取的模型已合并到上方「选择模型版本」的 ☁️ 在线分组里，
            // 不再重复显示下拉框。如果该模板没有预设模型（custom），这里兜底显示。
            if (_cachedModels.isNotEmpty &&
                _selectedTemplateId == ApiProviderTemplate.customId) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _cachedModels.contains(_modelController.text.trim())
                    ? _modelController.text.trim()
                    : null,
                decoration: InputDecoration(
                  labelText: isZh ? '已缓存模型（点击切换）' : 'Cached models (tap to switch)',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: _cachedModels.map((id) => DropdownMenuItem(
                  value: id,
                  child: Text(id, style: const TextStyle(fontSize: 13)),
                )).toList(),
                onChanged: (v) {
                  if (v != null) {
                    setState(() {
                      _modelController.text = v;
                      _selectedModelId = v;
                    });
                  }
                },
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _systemPromptController,
              decoration: InputDecoration(
                labelText: l.tr('systemPrompt'),
                hintText: 'You are a helpful assistant...',
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            Text('${l.tr('temperature')}: ${_temperature.toStringAsFixed(1)}',
                style: Theme.of(context).textTheme.bodyMedium),
            Slider(
              value: _temperature,
              min: 0.0,
              max: 2.0,
              divisions: 20,
              onChanged: (v) => setState(() => _temperature = v),
            ),
            const SizedBox(height: 8),
            Text('${l.tr('maxTokens')}: $_maxTokens',
                style: Theme.of(context).textTheme.bodyMedium),
            Slider(
              value: _maxTokens.toDouble(),
              min: 256,
              max: 8192,
              divisions: 31,
              onChanged: (v) => setState(() => _maxTokens = v.round()),
            ),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              onPressed: _isTesting ? null : _testConnection,
              icon: _isTesting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: Text(l.tr('testConnection')),
            ),
            if (_testResult.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _testSuccess
                      ? Colors.green.withValues(alpha: 0.1)
                      : Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _testResult,
                  style: TextStyle(
                    color: _testSuccess ? Colors.green : Colors.red,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: Text(l.tr('save')),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 模型版本切换器 ----------
  Widget _buildModelVersionSelector(bool isZh) {
    final t = ApiProviderTemplate.all
        .firstWhere((e) => e.id == _selectedTemplateId);
    if (t.models.isEmpty) {
      // 没有多个版本（比如 LM Studio），就只显示一个"单一模型"提示
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: t.color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Icon(Icons.memory, color: t.color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isZh
                  ? '此服务商仅单一模型：${t.defaultModel}'
                  : 'Single model: ${t.defaultModel}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ]),
      );
    }
    // v1.5.1：把动态拉取的模型（_cachedModels）和模板预设模型合并显示。
    // - 预设模型用 ⭐ 图标（t.models，来自模板硬编码）
    // - 在线模型用 ☁️ 图标（_cachedModels，点🔄刷新拉取）
    // 两组独立显示，中间有分隔标题。在线模型若和预设同名则去重（不重复显示）。
    final presetIds = t.models.map((m) => m.id).toSet();
    final onlineOnly = _cachedModels
        .where((id) => !presetIds.contains(id))
        .toList(growable: false);
    final hasOnline = onlineOnly.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.memory, color: t.color, size: 18),
          const SizedBox(width: 6),
          Text(isZh ? '选择模型版本' : 'Choose Model Version',
              style: Theme.of(context).textTheme.titleMedium),
        ]),
        const SizedBox(height: 4),
        Text(isZh ? '点一下即可切换，无需手动输入' : 'Tap to switch, no typing needed',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 10),
        // ===== 组 1：⭐ 推荐（模板预设模型）=====
        if (t.models.isNotEmpty) ...[
          _buildSectionLabel(
              isZh ? '⭐ 推荐' : '⭐ Recommended', t.color),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: t.models.map((m) {
              final selected = _selectedModelId == m.id;
              return FilterChip(
                selected: selected,
                showCheckmark: false,
                avatar: m.recommended
                    ? Icon(Icons.star, size: 14, color: t.color)
                    : null,
                onSelected: (_) => _selectModel(m),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(m.displayName(isZh)),
                    if (m.isFreeModel) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.greenAccent.shade100,
                          borderRadius: BorderRadius.circular(4),
                          border:
                              Border.all(color: Colors.green.withAlpha(120)),
                        ),
                        child: Text(
                          isZh ? '免费' : 'FREE',
                          style: const TextStyle(
                            color: Colors.green,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    if (m.note(isZh) != null && m.note(isZh)!.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Text(
                        m.note(isZh)!,
                        style: TextStyle(
                          fontSize: 10,
                          color: t.color.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
          ),
        ],
        // ===== 组 2：☁️ 在线拉取（动态模型）=====
        if (hasOnline) ...[
          const SizedBox(height: 10),
          _buildSectionLabel(
              isZh
                  ? '☁️ 在线拉取（点右侧🔄按钮刷新）'
                  : '☁️ Online (tap 🔄 to refresh)',
              Colors.blue.shade700),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: onlineOnly.map((id) {
              final selected = _selectedModelId == id ||
                  _modelController.text.trim() == id;
              return FilterChip(
                selected: selected,
                showCheckmark: false,
                avatar: Icon(Icons.cloud_outlined,
                    size: 14, color: Colors.blue.shade700),
                onSelected: (_) {
                  setState(() {
                    _selectedModelId = id;
                    _modelController.text = id;
                  });
                },
                label: Text(id, style: const TextStyle(fontSize: 13)),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  /// v1.5.1：模型分组的小标签（⭐推荐 / ☁️在线）
  Widget _buildSectionLabel(String text, Color color) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            )),
      ],
    );
  }

  // ---------- Template group builders ----------
  List<Widget> _buildGroupChips(bool isZh) {
    const groups = [
      (ApiProviderGroup.domestic, '国内服务商 / Domestic'),
      (ApiProviderGroup.international, '国际服务商 / International'),
      (ApiProviderGroup.local, '本地模型 / Local (no Key)'),
    ];
    final List<Widget> out = [];
    for (final (g, title) in groups) {
      final templates = ApiProviderTemplate.byGroup(g);
      final displayTitle =
          isZh ? title.split(' / ').first.trim() : title.split(' / ').last.trim();
      out.add(Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 2),
        child: Text('• $displayTitle',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      ));
      out.add(SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ...templates.map((t) => Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 6),
                  child: _buildTemplateChip(t, isZh),
                )),
            // Custom "clear" chip 放在每个组末尾（任意一组都能点）
            if (g == ApiProviderGroup.domestic)
              Padding(
                padding: const EdgeInsets.only(right: 6, bottom: 6),
                child: _buildCustomChip(isZh),
              ),
          ],
        ),
      ));
    }
    return out;
  }

  Widget _buildTemplateChip(ApiProviderTemplate t, bool isZh) {
    final selected = _selectedTemplateId == t.id;
    final name = isZh ? t.nameZh : t.nameEn;
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      onSelected: (_) {
        _applyTemplate(t);
      },
      avatar: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
            color: t.color, borderRadius: BorderRadius.circular(8)),
        child: Icon(t.icon, size: 14, color: Colors.white),
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name),
          if (t.hasFreeTier) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: isZh
                  ? (t.freeDetailZh.isEmpty
                      ? '提供永久可循环使用的免费 API 层'
                      : t.freeDetailZh)
                  : (t.freeDetailEn.isEmpty
                      ? 'Offers a permanently renewable free API tier'
                      : t.freeDetailEn),
              preferBelow: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.shade100,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.green.withAlpha(120)),
                ),
                child: Text(
                  isZh ? '部分免费' : 'PARTIAL FREE',
                  style: const TextStyle(
                      color: Colors.green,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCustomChip(bool isZh) {
    final selected = _selectedTemplateId == ApiProviderTemplate.customId;
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      onSelected: (_) {
        _applyTemplate(null);
      },
      avatar: const Icon(Icons.edit, size: 14),
      label: Text(isZh ? '自定义' : 'Custom'),
    );
  }

  Widget _templateInfoHint(bool isZh) {
    final t = ApiProviderTemplate.all
        .firstWhere((e) => e.id == _selectedTemplateId);
    final desc = isZh ? t.descZh : t.descEn;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: t.color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  desc.isEmpty
                      ? (isZh ? '已自动填入默认 Base URL 与推荐模型' : 'Auto-filled Base URL & default model')
                      : '${isZh ? '说明：' : 'Note: '}$desc',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                ),
              ),
            ],
          ),
          // v1.5.2：官网链接（点击跳转去注册账号 / 查 API Key）
          if (t.officialUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _openUrl(t.officialUrl),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new, size: 14, color: t.color),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isZh ? '访问官网（注册 / 查 API Key）' : 'Official site (signup / API key)',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: t.color,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// v1.5.2：用系统浏览器打开官网链接
  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }
}
