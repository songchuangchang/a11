import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import 'biometric_service.dart';
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
  // v1.7.33：XLSX 解析限额（复用 docx 的压缩/条目安全阀思路，独立命名便于后续调参）
  static const int _maxXlsxBytes = 30 * 1024 * 1024;
  static const int _maxXlsxEntries = 200;
  static const int _maxXlsxUncompressedBytes = 100 * 1024 * 1024;
  static const int _maxXlsxCells = 20000;

  final _log = LoggerService.instance;
  final _picker = ImagePicker();

  /// 从相册选一张照片
  Future<MessageAttachment?> pickImageFromGallery() async {
    BiometricService.inAppActivityTransition = true;
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
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.inAppActivityTransition = false;
      });
    }
  }

  /// 拍照
  Future<MessageAttachment?> pickImageFromCamera() async {
    BiometricService.inAppActivityTransition = true;
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
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.inAppActivityTransition = false;
      });
    }
  }

  /// 选文档（txt/md/log/csv/pdf/docx/xlsx）
  Future<MessageAttachment?> pickDocument() async {
    BiometricService.inAppActivityTransition = true;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'txt', 'md', 'markdown', 'log', 'csv', 'pdf', 'docx', 'xlsx',
        ],
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
        case 'csv':
          return await _processCsvFile(file, pf.name);
        case 'pdf':
          return await _processPdf(file, pf.name);
        case 'docx':
          return await _processDocx(file, pf.name);
        case 'xlsx':
          return await _processXlsx(file, pf.name);
        default:
          _log.warn('Unsupported file ext: $ext', tag: 'Att');
          return null;
      }
    } catch (e, st) {
      _log.error('pickDocument failed', error: e, stack: st, tag: 'Att');
      return null;
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        BiometricService.inAppActivityTransition = false;
      });
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

  /// v1.7.33：CSV → 按 RFC4180 风格解析（支持双引号包裹 + 逗号/分号/制表符分隔 + BOM），
  /// 输出为「表头 + 每行管道分隔」的纯文本，避免塞给模型时列错位。
  Future<MessageAttachment> _processCsvFile(File file, String name) async {
    final fileSize = await file.length();
    if (fileSize > _maxRawFileBytes) {
      _log.warn('CSV rejected: $name exceeds $_maxRawFileBytes bytes', tag: 'Att');
      return _errorAttachment(
          name, 'CSV 文件超过 ${_maxRawFileBytes ~/ (1024 * 1024)} MB 限制');
    }
    String text;
    try {
      final raw = await file.readAsString();
      // 去 UTF-8 BOM（Excel 导出的 CSV 常见），否则第一列表头会带隐形字符
      text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
      final rows = _parseCsv(text);
      if (rows.isEmpty) {
        text = '[CSV 内没有可解析的数据行]';
      } else {
        final lines = <String>[];
        lines.add('CSV 共 ${rows.length} 行（第一行为表头，若存在）');
        for (final row in rows) {
          final cells = row.map((c) => c.replaceAll(RegExp(r'[\r\n\t]+'), ' ')).toList();
          lines.add(cells.join(' | '));
        }
        text = lines.join('\n');
      }
      _log.info('CSV attachment: $name rows=${text.length}', tag: 'Att');
    } catch (e, st) {
      _log.error('CSV parse failed: $e', error: e, stack: st, tag: 'Att');
      text = '[CSV 解析失败: $e]';
    }
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.text,
      fileName: name,
      extractedText: _truncate(text),
    );
  }

  /// 公开桥接：CSV 解析（供单测直接验证，逻辑与 _processCsvFile 同源）
  static List<List<String>> parseCsv(String text) => _parseCsv(text);

  /// 公开桥接：XML 实体解码（供单测验证）
  static String decodeXmlEntities(String s) => _decodeXmlEntities(s);

  /// 极简 RFC4180 解析器：双引号包裹字段可含分隔符与换行，"" 转义为 "。
  /// 分隔符按首行出现频率自动判定（, > ; > \t）。
  /// 兼容 UTF-8 BOM、\r\n / \r / \n 三种换行。
  static List<List<String>> _parseCsv(String text) {
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    if (text.trim().isEmpty) return const [];
    final firstLine = text.split(RegExp(r'[\r\n]+')).first;
    final counts = <String, int>{',': 0, ';': 0, '\t': 0};
    for (final d in counts.keys) {
      var idx = firstLine.indexOf(d);
      while (idx != -1) {
        counts[d] = counts[d]! + 1;
        idx = firstLine.indexOf(d, idx + 1);
      }
    }
    final sep = counts.entries.reduce((a, b) => (a.value >= b.value ? a : b)).key;

    final rows = <List<String>>[];
    final row = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else if (ch == '\r' &&
            i + 1 < text.length &&
            text[i + 1] == '\n') {
          cell.write('\n');
          i++;
        } else {
          cell.write(ch);
        }
      } else if (ch == '"' && cell.isEmpty) {
        inQuotes = true;
      } else if (ch == sep) {
        row.add(cell.toString());
        cell.clear();
      } else if (ch == '\n' ||
          (ch == '\r' &&
              (i + 1 >= text.length || text[i + 1] != '\n'))) {
        row.add(cell.toString());
        cell.clear();
        rows.add(row.toList());
        row.clear();
      } else if (ch == '\r') {
        // CRLF 中的 \r：跳过，换行由 \n 统一处理
      } else {
        cell.write(ch);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row.toList());
    }
    return rows;
  }

  /// v1.7.33：XLSX（xlsx = zip 内的 OOXML 工作簿）→ 抽出各 sheet 的单元格文本，
  /// 输出为「# Sheet 名 + 行管道分隔」的纯文本。用现有 archive 依赖，不新增依赖。
  Future<MessageAttachment> _processXlsx(File file, String name) async {
    final fileSize = await file.length();
    if (fileSize > _maxXlsxBytes) {
      _log.warn('XLSX rejected: $name exceeds $_maxXlsxBytes bytes', tag: 'Att');
      return _errorAttachment(
          name, 'XLSX 文件超过 ${_maxXlsxBytes ~/ (1024 * 1024)} MB 限制');
    }
    String text;
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.files.length > _maxXlsxEntries) {
        return _errorAttachment(name, 'XLSX 压缩包条目超过 $_maxXlsxEntries 个限制');
      }
      final uncompressedBytes = archive.files.fold<int>(
        0,
        (total, entry) => total + entry.size,
      );
      if (uncompressedBytes > _maxXlsxUncompressedBytes) {
        return _errorAttachment(name,
            'XLSX 解压后大小超过 ${_maxXlsxUncompressedBytes ~/ (1024 * 1024)} MB 限制');
      }

      final buf = StringBuffer();
      var cells = 0;

      // sharedStrings：共享字符串表（xlsx 里字符串默认存索引）
      final sharedStrings = <String>[];
      final ssEntry = archive.findFile('xl/sharedStrings.xml');
      if (ssEntry != null) {
        final ssXml = utf8.decode(ssEntry.content as List<int>);
        // <si><t>text</t></si> 或 <si><r><t>..</t></r>...
        final siRe = RegExp(r'<si>(.*?)</si>', dotAll: true);
        final tRe = RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true);
        for (final m in siRe.allMatches(ssXml)) {
          final inner = m.group(1) ?? '';
          sharedStrings.add(_decodeXmlText(tRe.allMatches(inner).map((t) => t.group(1) ?? '').join()));
        }
      }

      // 按 workbook.xml 的 sheet 顺序找 sheet1.xml/sheet2.xml…
      final wbEntry = archive.findFile('xl/workbook.xml');
      final sheetOrder = <String>[];
      if (wbEntry != null) {
        final wbXml = utf8.decode(wbEntry.content as List<int>);
        final nameRe = RegExp(r'<sheet[^>]*name="([^"]*)"');
        for (final m in nameRe.allMatches(wbXml)) {
          sheetOrder.add(_decodeXmlEntities(m.group(1) ?? ''));
        }
      }
      for (var i = 1; i <= sheetOrder.length; i++) {
        final entry = archive.findFile('xl/worksheets/sheet$i.xml');
        if (entry == null) continue;
        final xml = utf8.decode(entry.content as List<int>);
        final sheetName = sheetOrder[i - 1].isEmpty ? 'Sheet$i' : sheetOrder[i - 1];
        buf.writeln('# $sheetName');

        final rowRe = RegExp(r'<row[^>]*r="(\d+)"[^>]*>(.*?)</row>', dotAll: true);
        final cellRe = RegExp(r'<c\b([^>]*)>(.*?)</c>|<c\b([^>]*)\s*/>', dotAll: true);
        var rowCount = 0;
        for (final rm in rowRe.allMatches(xml)) {
          if (rowCount++ >= 500) {
            buf.writeln('…[该表超过 500 行，已截断]');
            break;
          }
          final cellsInRow = <String>[];
          for (final cm in cellRe.allMatches(rm.group(2) ?? '')) {
            final attrs = cm.group(1) ?? cm.group(3) ?? '';
            final inner = cm.group(2) ?? '';
            final typeM = RegExp(r't="([^"]*)"').firstMatch(attrs);
            final type = typeM?.group(1);
            final vMatch = RegExp(r'<v[^>]*>(.*?)</v>', dotAll: true).firstMatch(inner);
            var value = '';
            if (type == 'inlineStr') {
              value = _decodeXmlText(
                  RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true)
                      .allMatches(inner)
                      .map((t) => t.group(1) ?? '')
                      .join());
            } else if (type == 's') {
              final idx = int.tryParse((vMatch?.group(1) ?? '').trim()) ?? -1;
              if (idx >= 0 && idx < sharedStrings.length) {
                value = sharedStrings[idx];
              }
            } else if (vMatch != null) {
              value = _decodeXmlText(vMatch.group(1) ?? '');
            }
            cellsInRow.add(value);
            if (++cells >= _maxXlsxCells) break;
          }
          buf.writeln(cellsInRow.join(' | '));
          if (cells >= _maxXlsxCells) {
            buf.writeln('…[单元格总数超过 $_maxXlsxCells，已截断]');
            break;
          }
        }
        buf.writeln();
        if (cells >= _maxXlsxCells) break;
      }
      text = buf.toString().trim();
      if (text.isEmpty) text = '[XLSX 内未找到可解析的工作表]';
      _log.info('xlsx attachment: $name cells=$cells', tag: 'Att');
    } catch (e, st) {
      _log.error('xlsx extract failed: $e', error: e, stack: st, tag: 'Att');
      text = '[xlsx 解析失败: $e]';
    }
    return MessageAttachment(
      id: const Uuid().v4(),
      type: AttachmentType.doc,
      fileName: name,
      extractedText: _truncate(text),
    );
  }

  /// 处理 XML 字符实体（仅做数值实体，字母实体的 5 个标准项已在 docx 分支处理）
  static String _decodeXmlText(String s) =>
      _decodeXmlEntities(RegExp(r'&#x([0-9a-fA-F]+);').allMatches(s).isEmpty
          ? s
          : s.replaceFirstMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
              (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16))));

  static String _decodeXmlEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

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
