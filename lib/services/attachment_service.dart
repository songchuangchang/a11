import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import 'logger_service.dart';

/// v1.3.6：📎 附件解析服务
///
/// 支持三类附件：
///   - text  : txt/md/log 等纯文本 → 读文件内容（截断到 30000 字符）
///   - image : 照片 → 复制到 app docs 目录用作缩略图，发 API 时再转 base64
///   - doc   : pdf/docx → 抽取文本（截断到 30000 字符）
///
/// 设计要点：
///   - 图片的 base64 不落库（避免 DB 膨胀），只在调 API 时由 [imageToBase64] 现转
///   - 文本类附件把抽取出来的文本存进 extractedText，发 API 时拼到用户消息正文里
class AttachmentService {
  static const int _maxTextChars = 30000; // 约 7.5k tokens，够用又不爆请求体
  static const int _maxRawFileBytes = 50 * 1024 * 1024;
  static const int _maxPdfBytes = 30 * 1024 * 1024;
  static const int _maxPdfPages = 500;
  static const int _maxDocxBytes = 30 * 1024 * 1024;
  static const int _maxDocxEntries = 200;
  static const int _maxDocxUncompressedBytes = 100 * 1024 * 1024;

  final _log = LoggerService.instance;
  final _picker = ImagePicker();

  /// 从相册选一张照片
  Future<MessageAttachment?> pickImageFromGallery() async {
    try {
      final xf = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (xf == null) return null;
      return await _processImage(xf);
    } catch (e, st) {
      _log.error('pickImageFromGallery failed',
          error: e, stack: st, tag: 'Att');
      return null;
    }
  }

  /// 拍照
  Future<MessageAttachment?> pickImageFromCamera() async {
    try {
      final xf = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 85,
      );
      if (xf == null) return null;
      return await _processImage(xf);
    } catch (e, st) {
      _log.error('pickImageFromCamera failed', error: e, stack: st, tag: 'Att');
      return null;
    }
  }

  /// 选文档（txt/md/log/pdf/docx）
  Future<MessageAttachment?> pickDocument() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'md', 'markdown', 'log', 'pdf', 'docx'],
        withData: false,
      );
      if (result == null || result.files.isEmpty) return null;
      final pf = result.files.first;
      final path = pf.path;
      if (path == null) return null;
      final file = File(path);
      if (!await file.exists()) return null;
      final fileSize = await file.length();
      if (fileSize > _maxRawFileBytes) {
        _log.warn('Document rejected: $path exceeds $_maxRawFileBytes bytes',
            tag: 'Att');
        return _errorAttachment(
            pf.name, '附件超过 ${_maxRawFileBytes ~/ (1024 * 1024)} MB 限制');
      }
      final ext = _ext(path).toLowerCase();
      switch (ext) {
        case 'txt':
        case 'md':
        case 'markdown':
        case 'log':
          return await _processTextFile(file, pf.name);
        case 'pdf':
          return await _processPdf(file, pf.name);
        case 'docx':
          return await _processDocx(file, pf.name);
        default:
          _log.warn('Unsupported file ext: $ext', tag: 'Att');
          return null;
      }
    } catch (e, st) {
      _log.error('pickDocument failed', error: e, stack: st, tag: 'Att');
      return null;
    }
  }

  /// 发 API 时把图片本地文件转成 base64（不含 data: 前缀，由调用方拼）
  Future<String?> imageToBase64(MessageAttachment att) async {
    if (att.type != AttachmentType.image || att.localPath == null) return null;
    try {
      final bytes = await File(att.localPath!).readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      _log.error('imageToBase64 failed: $e', tag: 'Att');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  Future<MessageAttachment?> _processImage(XFile xf) async {
    final imageSize = await File(xf.path).length();
    if (imageSize > _maxRawFileBytes) {
      _log.warn('Image rejected: ${xf.path} exceeds $_maxRawFileBytes bytes',
          tag: 'Att');
      return null;
    }
    final ext = _ext(xf.path).toLowerCase();
    final mime = xf.mimeType ?? 'image/jpeg';
    // 复制到 app docs 目录持久化（避免相册/缓存路径被系统清理后缩略图失效）
    final dir = await getApplicationDocumentsDirectory();
    final dest = '${dir.path}/att_${const Uuid().v4()}.$ext';
    await File(xf.path).copy(dest);
    _log.info('Image attachment: $dest (${_kbOf(dest)} KB) mime=$mime',
        tag: 'Att');
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.image,
      fileName: xf.name.isEmpty ? 'image.$ext' : xf.name,
      localPath: dest,
      mimeType: mime,
    );
  }

  Future<MessageAttachment> _processTextFile(File file, String name) async {
    final raw = await file.readAsString(); // 默认 UTF-8
    final text = _truncate(raw);
    _log.info('Text attachment: $name chars=${raw.length}', tag: 'Att');
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.text,
      fileName: name,
      extractedText: text,
    );
  }

  Future<MessageAttachment> _processPdf(File file, String name) async {
    final fileSize = await file.length();
    if (fileSize > _maxPdfBytes) {
      _log.warn('PDF rejected: $name exceeds $_maxPdfBytes bytes', tag: 'Att');
      return _errorAttachment(
          name, 'PDF 文件超过 ${_maxPdfBytes ~/ (1024 * 1024)} MB 限制');
    }
    String text = '';
    // v1.6.8 修复 Bug#8：PdfDocument 持有原生资源，仅在早退路径 dispose 不够，
    // 正常路径和 catch 路径都泄漏。改为 try/finally 保证一定释放。
    PdfDocument? doc;
    try {
      final bytes = await file.readAsBytes();
      doc = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(doc);
      final pageCount = doc.pages.count;
      if (pageCount > _maxPdfPages) {
        _log.warn('PDF rejected: $name has $pageCount pages', tag: 'Att');
        return _errorAttachment(name, 'PDF 页数超过 $_maxPdfPages 页限制');
      }
      final buf = StringBuffer();
      for (int i = 0; i < doc.pages.count; i++) {
        try {
          buf.writeln(
              extractor.extractText(startPageIndex: i, endPageIndex: i));
        } catch (_) {
          // 跳过无法解析的页
        }
        if (buf.length >= _maxTextChars) break;
      }
      text = buf.toString();
    } catch (e, st) {
      _log.error('PDF extract failed: $e', error: e, stack: st, tag: 'Att');
      text = '[PDF 文本抽取失败: $e]';
    } finally {
      doc?.dispose();
    }
    final truncated = _truncate(text);
    _log.info('PDF attachment: $name chars=${text.length}', tag: 'Att');
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.doc,
      fileName: name,
      extractedText: truncated,
    );
  }

  Future<MessageAttachment> _processDocx(File file, String name) async {
    final fileSize = await file.length();
    if (fileSize > _maxDocxBytes) {
      _log.warn('DOCX rejected: $name exceeds $_maxDocxBytes bytes',
          tag: 'Att');
      return _errorAttachment(
          name, 'DOCX 压缩包超过 ${_maxDocxBytes ~/ (1024 * 1024)} MB 限制');
    }
    String text = '';
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.files.length > _maxDocxEntries) {
        return _errorAttachment(name, 'DOCX 压缩包条目超过 $_maxDocxEntries 个限制');
      }
      final uncompressedBytes = archive.files.fold<int>(
        0,
        (total, entry) => total + entry.size,
      );
      if (uncompressedBytes > _maxDocxUncompressedBytes) {
        return _errorAttachment(name,
            'DOCX 解压后大小超过 ${_maxDocxUncompressedBytes ~/ (1024 * 1024)} MB 限制');
      }
      final docEntry = archive.findFile('word/document.xml');
      if (docEntry == null) {
        text = '[docx 内未找到 word/document.xml]';
      } else {
        final xml = utf8.decode(docEntry.content as List<int>);
        // 段落结束补换行，保留基本结构；再剥掉其余 XML 标签
        text = xml
            .replaceAll(RegExp(r'</w:p>'), '\n')
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trim();
        // 处理 XML 转义
        text = text
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&apos;', "'");
      }
    } catch (e, st) {
      _log.error('docx extract failed: $e', error: e, stack: st, tag: 'Att');
      text = '[docx 文本抽取失败: $e]';
    }
    final truncated = _truncate(text);
    _log.info('docx attachment: $name chars=${text.length}', tag: 'Att');
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.doc,
      fileName: name,
      extractedText: truncated,
    );
  }

  MessageAttachment _errorAttachment(String name, String message) {
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.doc,
      fileName: name,
      extractedText: '[附件无法处理: $message]',
    );
  }

  String _truncate(String s) {
    if (s.length <= _maxTextChars) return s;
    return '${s.substring(0, _maxTextChars)}\n\n…[内容超过 $_maxTextChars 字符，已截断]';
  }

  String _ext(String path) => path.split('.').last;

  Future<int> _kbOf(String path) async {
    try {
      final s = await File(path).length();
      return (s / 1024).round();
    } catch (_) {
      return 0;
    }
  }
}
