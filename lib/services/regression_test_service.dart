import 'dart:io';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../plugins/builtin_plugins.dart';
import 'api_service.dart';
import 'logger_service.dart';
import 'react_parser.dart';
import 'storage_service.dart';

/// 单个回归测试用例的结果
///
/// 自动判定（autoPassed）+ 人工二次确认（userVerdict）双轨：
/// - autoPassed=true  → 系统判定 AI 回复符合预期
/// - autoPassed=false → 系统判定异常（用户仍可标"正确"覆盖）
/// - userVerdict=null → 用户尚未确认
class RegressionTestResult {
  final String id;
  final String name;
  final String description;
  final bool autoPassed;
  final String detail;
  final String rawResponse;
  bool? userVerdict; // null=未确认, true=正确, false=异常

  RegressionTestResult({
    required this.id,
    required this.name,
    required this.description,
    required this.autoPassed,
    required this.detail,
    required this.rawResponse,
    this.userVerdict,
  });
}

/// AI 回归测试服务（v1.4.4 新增）
///
/// 与 SelfCheckService 的区别：
///   - SelfCheckService：检查 App 自身基础设施（DB schema / 日志脱敏 / API 连通性等）
///   - RegressionTestService：发送固定输入，验证 AI 模型行为是否符合预期
///
/// 三类用例：
///   1. 反问对话框检测（关键词触发 AI 输出 <ask_user> 标签）
///   2. TXT 附件内容识别（附件含 "12345678"，问"什么数字"，AI 应答出 12345678）
///   3. 图片附件内容识别（图片含 "12345678"，问"什么数字"，AI 应答出 12345678）
///
/// 自动判定 + 人工二次确认：
///   系统按规则自动判 pass/fail，用户可在结果上点「正确」覆盖或「异常」标错。
class RegressionTestService {
  static final _logger = LoggerService.instance;

  /// 固定测试期望内容（所有附件测试都用这串数字）
  static const String kExpectedContent = '12345678';

  /// 触发反问对话框的关键词（用户可发送这些词让 AI 主动反问）
  static const List<String> kRebuttalTriggers = [
    '测试反问',
    '请反问我一个问题',
    '用 <ask_user> 协议问我',
  ];

  // ===========================================================================
  // 一、运行时生成固定测试文件
  // ===========================================================================

  /// 生成/复用 TXT 测试文件
  ///
  /// 写入固定内容 [kExpectedContent] 到 app docs 目录的 regression_test_text.txt
  static Future<File> ensureTxtTestFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/regression_test_text.txt');
    if (!await f.exists() || (await f.readAsString()) != kExpectedContent) {
      await f.writeAsString(kExpectedContent);
      _logger.info('[REGRESSION] Generated TXT test file: ${f.path}', tag: 'Reg');
    }
    return f;
  }

  /// 生成/复用 图片测试文件（白底黑字"12345678"）
  ///
  /// 用 Canvas 绘制 400x100 白底图片，黑色 40px 文字居中。
  static Future<File> ensureImageTestFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/regression_test_image.png');
    if (await f.exists() && await f.length() > 0) {
      return f; // 已生成则复用
    }

    const width = 400;
    const height = 100;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // 白底
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    // 黑字 "12345678"
    final paragraph = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        fontSize: 40,
        fontWeight: ui.FontWeight.bold,
        textAlign: ui.TextAlign.left,
      ),
    )
      ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000), fontSize: 40))
      ..addText(kExpectedContent);
    final p = paragraph.build()
      ..layout(ui.ParagraphConstraints(width: width.toDouble()));

    // 文字居中绘制
    canvas.drawParagraph(p, const ui.Offset(40, 30));

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw StateError('regression_test_image: toByteData returned null');
    }
    final png = byteData.buffer.asUint8List();
    await f.writeAsBytes(png);
    _logger.info(
        '[REGRESSION] Generated PNG test file: ${f.path} (${png.length} bytes)',
        tag: 'Reg');
    return f;
  }

  // ===========================================================================
  // 二、运行测试用例
  // ===========================================================================

  /// 运行所有用例（消耗 token，需用户手动触发）
  ///
  /// 顺序执行：对话链路 → 反问 → TXT → 图片。每条结果记录 AI 原始回复，便于人工复核。
  static Future<List<RegressionTestResult>> runAll({bool isZh = true}) async {
    final results = <RegressionTestResult>[];
    results.add(await runDialogLinkTest(isZh));
    results.add(await runRebuttalDialogTest(isZh));
    results.add(await runTxtAttachmentTest(isZh));
    results.add(await runImageAttachmentTest(isZh));

    final passCount =
        results.where((r) => r.autoPassed && r.userVerdict != false).length;
    _logger.info(
        '[REGRESSION] 测试完成：$passCount/${results.length} 自动通过；'
        '${results.where((r) => r.userVerdict == true).length} 项用户确认正确，'
        '${results.where((r) => r.userVerdict == false).length} 项用户标记异常',
        tag: 'Reg');
    return results;
  }

  /// 用例 0：对话链路测试（v1.4.6 合并自原 SelfCheckService._checkDialogTest）
  ///
  /// 发送短消息，验证完整对话链路：API 连通 → 返回非空回复。
  /// 自动判定：resp 非空 → 通过。
  static Future<RegressionTestResult> runDialogLinkTest(bool isZh) async {
    const id = 'dialog_link';
    final name = isZh ? '对话链路测试' : 'Dialog link test';
    final desc = isZh
        ? '发送"请只回复「测试成功」四个字"，AI 应返回非空回复'
        : 'Send "请只回复「测试成功」四个字", AI should return a non-empty reply';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    final apiSvc = ApiService();
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: '请只回复「测试成功」四个字',
    );

    try {
      final resp = await apiSvc.completeChat(
        config: cfg,
        messages: [userMsg],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 30),
      );
      final pass = resp.isNotEmpty;
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: pass,
        detail: pass
            ? (isZh ? '收到 ${resp.length} 字回复' : 'Got ${resp.length}-char reply')
            : (isZh ? '异常：回复为空' : 'Error: empty reply'),
        rawResponse: resp,
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  /// 用例 1：反问对话框检测
  ///
  /// 构造一个会触发 AI 输出 `<ask_user>` 标签的提示词，
  /// 调用 completeChat，用 parseReActOutput 检查返回里是否含 ask_user 标签。
  static Future<RegressionTestResult> runRebuttalDialogTest(bool isZh) async {
    const id = 'rebuttal_dialog';
    final name = isZh ? '反问对话框检测' : 'Rebuttal dialog detection';
    final desc = isZh
        ? '发送"测试反问"关键词，AI 应输出 <ask_user> 标签触发反问对话框'
        : 'Send "测试反问" keyword, AI should output the <ask_user> tag to trigger the rebuttal dialog';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    final apiSvc = ApiService();
    // 在 system prompt 里注入 ReAct 协议说明，让 AI 知道可以用 <ask_user>
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: '${kRebuttalTriggers.first}：请用 <ask_user> 标签向我提问一个'
          '简单问题，例如"你喜欢什么颜色？"，可选附上 2~3 个选项让用户选。',
    );
    final systemMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.system,
      content: '${cfg.systemPrompt}\n${buildReactSystemPromptFromPlugins(builtinReActPlugins)}',
    );

    try {
      final resp = await apiSvc.completeChat(
        config: cfg.copyWith(systemPrompt: ''), // system 已通过 systemMsg 注入
        messages: [systemMsg, userMsg],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 60),
      );
      final parsed = parseReActOutput(resp);
      final hasAskUser = parsed.any((p) => p['type'] == 'ask_user');
      final askPiece = parsed.firstWhere(
        (p) => p['type'] == 'ask_user',
        orElse: () => <String, String>{},
      );
      final detail = hasAskUser
          ? (isZh
              ? 'AI 输出 <ask_user> 标签（内容：${askPiece['content'] ?? ''}）'
              : 'AI output <ask_user> tag (content: ${askPiece['content'] ?? ''})')
          : (isZh ? 'AI 未输出 <ask_user> 标签' : 'AI did not output <ask_user> tag');
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: hasAskUser,
        detail: detail,
        rawResponse: resp,
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  /// 用例 2：TXT 附件内容识别
  ///
  /// 构造 MessageAttachment(type: text, extractedText: "12345678")，
  /// 发送"附件里写着什么数字？"，AI 应答出 "12345678"。
  static Future<RegressionTestResult> runTxtAttachmentTest(bool isZh) async {
    const id = 'txt_attachment';
    final name = isZh ? 'TXT 附件内容识别' : 'TXT attachment content recognition';
    final desc = isZh
        ? '附件内容为"12345678"，问"附件里写着什么数字"，AI 应答出 12345678'
        : 'Attachment contains "12345678"; ask what number is written in it, AI should answer 12345678';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    // 同时生成实际文件并复用，方便后续手动调试
    await ensureTxtTestFile();

    final apiSvc = ApiService();
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: '请看附件，告诉我里面写着什么数字（只需回答数字本身，不要解释）。',
    )..attachments.add(MessageAttachment(
        id: const Uuid().v4(),
        type: AttachmentType.text,
        fileName: 'regression_test_text.txt',
        extractedText: kExpectedContent,
      ));

    return _runAttachmentTest(id, name, desc, cfg, userMsg, apiSvc, isZh);
  }

  /// 用例 3：图片附件内容识别
  ///
  /// 生成白底黑字"12345678"PNG，构造 MessageAttachment(type: image)，
  /// 发送"图片里写着什么数字？"，AI 应答出 "12345678"。
  static Future<RegressionTestResult> runImageAttachmentTest(bool isZh) async {
    const id = 'image_attachment';
    final name = isZh ? '图片附件内容识别' : 'Image attachment content recognition';
    final desc = isZh
        ? '图片含"12345678"字样，问"图片里写着什么数字"，AI 应答出 12345678'
        : 'Image contains "12345678"; ask what number is written in it, AI should answer 12345678';

    final cfg = await _getFirstApiConfig();
    if (cfg == null) {
      return _skipped(
          id, name, desc, isZh ? '未配置 API' : 'No API configured', isZh);
    }

    final imgFile = await ensureImageTestFile();

    final apiSvc = ApiService();
    final userMsg = ChatMessage.create(
      conversationId: 'regression_test',
      role: MessageRole.user,
      content: '请看附件图片，告诉我图片里写着什么数字（只需回答数字本身，不要解释）。',
    )..attachments.add(MessageAttachment(
        id: const Uuid().v4(),
        type: AttachmentType.image,
        fileName: 'regression_test_image.png',
        localPath: imgFile.path,
        mimeType: 'image/png',
      ));

    return _runAttachmentTest(id, name, desc, cfg, userMsg, apiSvc, isZh);
  }

  // ===========================================================================
  // 三、辅助方法
  // ===========================================================================

  /// 通用附件测试：发送 user 消息（含附件）→ 检查 AI 回复是否包含期望数字
  static Future<RegressionTestResult> _runAttachmentTest(
    String id,
    String name,
    String desc,
    dynamic cfg, // ApiConfig
    ChatMessage userMsg,
    ApiService apiSvc,
    bool isZh,
  ) async {
    try {
      final resp = await apiSvc.completeChat(
        config: cfg,
        messages: [userMsg],
        reasoningEffort: 'low',
        timeout: const Duration(seconds: 90),
      );

      // 提取 AI 最终答案（若 ReAct 标签包裹，先解析）
      final parsed = parseReActOutput(resp);
      final answerPiece = parsed.firstWhere(
        (p) => p['type'] == 'answer',
        orElse: () => <String, String>{'type': 'answer', 'content': resp},
      );
      final answerText = (answerPiece['content'] ?? resp).trim();

      final matched = matchExpectedContent(answerText, kExpectedContent);
      final detail = matched
          ? (isZh
              ? 'AI 回复正确：包含 "$kExpectedContent"'
              : 'AI reply correct: contains "$kExpectedContent"')
          : (isZh
              ? 'AI 回复异常：未包含 "$kExpectedContent"（实际回复：'
                  '${answerText.length > 100 ? '${answerText.substring(0, 100)}...' : answerText}）'
              : 'AI reply abnormal: "$kExpectedContent" not found (actual reply: '
                  '${answerText.length > 100 ? '${answerText.substring(0, 100)}...' : answerText})');
      return RegressionTestResult(
        id: id,
        name: name,
        description: desc,
        autoPassed: matched,
        detail: detail,
        rawResponse: resp,
      );
    } catch (e) {
      return _error(id, name, desc, e.toString(), isZh);
    }
  }

  /// 内容匹配规则（纯函数，可单测）
  ///
  /// 满足以下任一条件即视为通过：
  ///   1. 回复完全等于期望（trim 后）
  ///   2. 回复包含期望内容（连写）
  ///   3. 回复包含期望数字（允许 8 个数字间有空格/破折号分隔）
  ///   4. 回复里逐字符匹配期望内容的所有数字字符（如"1 2 3 4 5 6 7 8"）
  static bool matchExpectedContent(String response, String expected) {
    final r = response.trim();
    final e = expected.trim();
    if (r.isEmpty) return false;

    // 1. 完全相等
    if (r == e) return true;

    // 2. 包含期望内容
    if (r.contains(e)) return true;

    // 3. 允许分隔符（空格/破折号/逗号）插入到数字之间
    // 提取回复里的所有数字字符
    final digitsInResp = r.replaceAll(RegExp(r'[^0-9]'), '');
    final digitsInExp = e.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsInResp == digitsInExp && digitsInExp.isNotEmpty) {
      return true;
    }

    // 4. 回复里包含期望的连续数字（防御性兜底，覆盖 OCR 可能把 8 识别成 B 等）
    if (digitsInResp.contains(digitsInExp)) {
      return true;
    }

    return false;
  }

  /// 从 StorageService 取第一个 ApiConfig（v1.4.2 SelfCheckService 同款逻辑）
  static Future<ApiConfig?> _getFirstApiConfig() async {
    try {
      final storage = StorageService.instance;
      final configs = await storage.getApiConfigs();
      return configs.isEmpty ? null : configs.first;
    } catch (e) {
      _logger.warn('[REGRESSION] _getFirstApiConfig failed: $e', tag: 'Reg');
      return null;
    }
  }

  static RegressionTestResult _skipped(
      String id, String name, String desc, String reason, bool isZh) {
    return RegressionTestResult(
      id: id,
      name: name,
      description: desc,
      autoPassed: true,
      detail: isZh ? '跳过：$reason' : 'Skipped: $reason',
      rawResponse: '',
    );
  }

  static RegressionTestResult _error(
      String id, String name, String desc, String err, bool isZh) {
    return RegressionTestResult(
      id: id,
      name: name,
      description: desc,
      autoPassed: false,
      detail: isZh ? '错误：$err' : 'Error: $err',
      rawResponse: '',
    );
  }
}
