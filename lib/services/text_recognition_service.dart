import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'logger_service.dart';

class TextRecognitionResult {
  final String fileName;
  final String text;
  final int charCount;
  final int durationMs;
  final bool success;
  final String? errorKind;

  const TextRecognitionResult({
    required this.fileName,
    required this.text,
    required this.charCount,
    required this.durationMs,
    required this.success,
    this.errorKind,
  });

  bool get isUsable => success && text.trim().isNotEmpty;
}

/// 本机 OCR 封装。
///
/// 业务侧只关心“图片路径 -> 可注入上下文的文本”。实际识别使用 Google ML Kit
/// Text Recognition 的 Flutter 插件层；日志只记录文件名、字符数、耗时和错误类别。
class TextRecognitionService {
  static const int maxOcrChars = 12000;

  Future<TextRecognitionResult> recognizeImagePath(String imagePath) async {
    final fileName = p.basename(imagePath);
    final start = DateTime.now();
    TextRecognizer? recognizer;
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        return _result(fileName, '图片文件不存在', start, 'missing');
      }
      recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
      final input = InputImage.fromFile(file);
      final recognized = await recognizer.processImage(input);
      final text = _sanitize(recognized.text);
      return _result(fileName, text, start, null,
          success: text.trim().isNotEmpty);
    } catch (e) {
      LoggerService.instance.warn(
        'OCR failed: file=${_safeLogName(fileName)}, error=${e.runtimeType}',
        tag: 'OCR',
      );
      return _result(fileName, '[未识别到文字]', start, e.runtimeType.toString());
    } finally {
      if (recognizer != null) {
        try {
          await recognizer.close();
        } catch (_) {
          // 资源释放失败不影响 OCR 结果返回。
        }
      }
    }
  }

  TextRecognitionResult _result(
    String fileName,
    String text,
    DateTime start,
    String? errorKind, {
    bool success = false,
  }) {
    final sanitized = _sanitize(text);
    return TextRecognitionResult(
      fileName: fileName,
      text: sanitized,
      charCount: sanitized.trim().length,
      durationMs: DateTime.now().difference(start).inMilliseconds,
      success: success,
      errorKind: errorKind,
    );
  }

  String _sanitize(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= maxOcrChars) return trimmed;
    return '${trimmed.substring(0, maxOcrChars)}\n…[OCR 内容过长，已截断]';
  }

  String _safeLogName(String name) {
    final base = p.basename(name);
    return base.replaceAll(RegExp(r'[^\w\-. ()\[\]]'), '_');
  }
}
