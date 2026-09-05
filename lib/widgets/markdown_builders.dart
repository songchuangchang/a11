import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';

/// v1.7.37：AI 输出多功能化 —— 代码块一键复制 + 表格复制/下载。
///
/// 注意（踩坑）：flutter_markdown 0.7.7+1 的 builder.dart 在 visitElementAfter
/// 中对 'table' 标签会用 `_buildTable()` 无条件覆盖自定义 builder 的返回值，
/// 因此不能直接对 'table' 注册 builder。这里用自定义 [NexusTableSyntax]
/// 把 GFM 表格改写成 'nx_table' 标签（整表原始文本塞进单个 md.Text 子节点），
/// 再由 [TableBuilder] 自行解析渲染。
class NexusTableSyntax extends md.BlockSyntax {
  NexusTableSyntax();

  /// 分隔行：`| --- | :---: | ---: |` 形式（至少两列）
  static final RegExp _separatorPattern = RegExp(
    r'^\s*\|?(\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?\s*$',
  );

  @override
  RegExp get pattern => RegExp(r'.*'); // 不会被用到（canParse 已重写）

  @override
  bool canEndBlock(md.BlockParser parser) => true;

  @override
  bool canParse(md.BlockParser parser) {
    // 当前行需含 '|'（表头），下一行是分隔行
    return parser.current.content.contains('|') &&
        parser.matchesNext(_separatorPattern);
  }

  @override
  md.Node? parse(md.BlockParser parser) {
    final sb = StringBuffer();
    sb.writeln(parser.current.content); // 表头行
    parser.advance();
    sb.writeln(parser.current.content); // 分隔行
    parser.advance();
    while (!parser.isDone && !md.BlockSyntax.isAtBlockEnd(parser)) {
      sb.writeln(parser.current.content);
      parser.advance();
    }
    return md.Element('nx_table', [md.Text(sb.toString().trimRight())]);
  }
}

/// 从元素树提取纯文本（含嵌套 code 元素）
String _extractText(md.Node node) {
  if (node is md.Text) return node.text;
  if (node is md.Element) {
    return (node.children ?? []).map(_extractText).join();
  }
  return '';
}

/// 代码块 builder：顶部 header（语言名 + 复制按钮），下方横向滚动代码区。
class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) => null;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = _extractText(element);
    var language = '';
    if (element.children != null && element.children!.isNotEmpty) {
      final first = element.children!.first;
      if (first is md.Element && first.tag == 'code') {
        final cls = first.attributes['class'] ?? '';
        if (cls.startsWith('language-')) {
          language = cls.substring('language-'.length);
        }
      }
    }
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  language.isEmpty ? (zh ? '代码' : 'Code') : language,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(zh ? '已复制代码' : 'Code copied'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.content_copy, size: 13, color: cs.primary),
                      const SizedBox(width: 3),
                      Text(
                        zh ? '复制' : 'Copy',
                        style: TextStyle(fontSize: 11, color: cs.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: cs.onSurface,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 表格 builder：渲染表格 + 「复制 CSV / 复制 Markdown / 下载 CSV」操作行。
class TableBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) => null;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final raw = _extractText(element);
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;

    List<String> splitRow(String line) {
      var s = line;
      if (s.startsWith('|')) s = s.substring(1);
      if (s.endsWith('|')) s = s.substring(0, s.length - 1);
      return s.split('|').map((c) => c.trim()).toList();
    }

    final header = splitRow(lines[0]);
    // lines[1] 是分隔行，跳过
    final rows = lines.skip(2).map(splitRow).toList();
    final columnCount = header.length;

    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final bodyStyle = TextStyle(fontSize: 12, color: cs.onSurface);
    final headStyle = bodyStyle.copyWith(fontWeight: FontWeight.bold);

    String toCsv() {
      String cell(String v) {
        if (v.contains(',') || v.contains('"') || v.contains('\n')) {
          return '"${v.replaceAll('"', '""')}"';
        }
        return v;
      }

      final sb = StringBuffer();
      sb.writeln(header.map(cell).join(','));
      for (final r in rows) {
        sb.writeln(r.map(cell).join(','));
      }
      return sb.toString();
    }

    String toMarkdown() {
      String row(List<String> cells) => '| ${cells.join(' | ')} |';
      final sb = StringBuffer();
      sb.writeln(row(header));
      sb.writeln('| ${List.filled(columnCount, '---').join(' | ')} |');
      for (final r in rows) {
        sb.writeln(row(r));
      }
      return sb.toString();
    }

    void copy(String text, String msg) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
    }

    Future<void> downloadCsv() async {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File(
            '${dir.path}${Platform.pathSeparator}nexus_table_${DateTime.now().millisecondsSinceEpoch}.csv');
        await file.writeAsString(toCsv());
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(zh ? '已保存：${file.path}' : 'Saved: ${file.path}'),
            duration: const Duration(seconds: 4),
          ),
        );
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(zh ? '保存失败：$e' : 'Save failed: $e')),
        );
      }
    }

    Widget cell(String text, {required bool isHeader}) => Container(
          color: isHeader ? cs.surfaceContainerHigh : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(text, style: isHeader ? headStyle : bodyStyle),
        );

    final btnStyle = TextButton.styleFrom(
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 11),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: cs.outlineVariant, width: 0.5),
            children: [
              TableRow(
                children: header.map((h) => cell(h, isHeader: true)).toList(),
              ),
              for (final r in rows)
                TableRow(
                  children: [
                    for (var i = 0; i < columnCount; i++)
                      cell(i < r.length ? r[i] : '', isHeader: false),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              style: btnStyle,
              onPressed: () =>
                  copy(toCsv(), zh ? '已复制 CSV' : 'CSV copied'),
              child: Text(zh ? '复制 CSV' : 'Copy CSV'),
            ),
            TextButton(
              style: btnStyle,
              onPressed: () => copy(
                  toMarkdown(), zh ? '已复制 Markdown' : 'Markdown copied'),
              child: Text(zh ? '复制 Markdown' : 'Copy Markdown'),
            ),
            TextButton(
              style: btnStyle,
              onPressed: downloadCsv,
              child: Text(zh ? '下载 CSV' : 'Download CSV'),
            ),
          ],
        ),
      ],
    );
  }
}
