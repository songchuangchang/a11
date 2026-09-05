// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:aichat/services/attachment_service.dart';

/// AttachmentService.parseCsv / decodeXmlEntities 单元测试
///
/// 覆盖：
///   - CSV：逗号/分号/制表符分隔符自动判定
///   - CSV：双引号包裹字段（含分隔符与换行）
///   - CSV："" 转义为 "
///   - CSV：UTF-8 BOM
///   - CSV：\r\n / \r / \n 三种换行
///   - CSV：空行/尾部无换行
///   - XML 实体：&amp; &lt; &gt; &quot; &apos; 五个标准项
void main() {
  group('parseCsv', () {
    test('逗号分隔与表头行', () {
      final rows = AttachmentService.parseCsv('a,b,c\n1,2,3\n');
      expect(rows, [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
    });

    test('分号分隔自动判定', () {
      final rows = AttachmentService.parseCsv('a;b;c\n1;2;3');
      expect(rows.length, 2);
      expect(rows[0], ['a', 'b', 'c']);
      expect(rows[1], ['1', '2', '3']);
    });

    test('制表符分隔自动判定', () {
      final rows = AttachmentService.parseCsv('a\tb\tc\n1\t2\t3');
      expect(rows.length, 2);
      expect(rows[0], ['a', 'b', 'c']);
      expect(rows[1], ['1', '2', '3']);
    });

    test('双引号字段包含分隔符', () {
      final rows = AttachmentService.parseCsv('"a,b",c\n"x,y",z');
      expect(rows, [
        ['a,b', 'c'],
        ['x,y', 'z'],
      ]);
    });

    test('双引号 "" 转义为单个 "', () {
      final rows = AttachmentService.parseCsv('a\n"say ""hi"""');
      expect(rows[1], ['say "hi"']);
    });

    test('引号内换行', () {
      final rows = AttachmentService.parseCsv('a,b\n"x\ny",z');
      expect(rows.length, 2);
      expect(rows[1], ['x\ny', 'z']);
    });

    test('UTF-8 BOM 剥离', () {
      final rows = AttachmentService.parseCsv('\uFEFFa,b\n1,2');
      expect(rows[0], ['a', 'b']);
    });

    test('兼容 CRLF 换行', () {
      final rows = AttachmentService.parseCsv('a,b\r\n1,2\r\n');
      expect(rows, [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });

    test('兼容单独 CR 换行（老 Mac）', () {
      final rows = AttachmentService.parseCsv('a,b\r1,2\r3,4');
      expect(rows.length, 3);
      expect(rows[1], ['1', '2']);
      expect(rows[2], ['3', '4']);
    });

    test('无换行的单行', () {
      final rows = AttachmentService.parseCsv('only-one-row');
      expect(rows, [['only-one-row']]);
    });

    test('空文本返回空列表', () {
      expect(AttachmentService.parseCsv(''), isEmpty);
      expect(AttachmentService.parseCsv('   '), isEmpty);
    });

    test('尾随逗号产出空单元格', () {
      final rows = AttachmentService.parseCsv('a,b,\n1,2,');
      expect(rows[0], ['a', 'b', '']);
      expect(rows[1], ['1', '2', '']);
    });
  });

  group('decodeXmlEntities', () {
    test('五个标准实体', () {
      expect(
        AttachmentService.decodeXmlEntities('&amp; &lt; &gt; &quot; &apos;'),
        '& < > " \'',
      );
    });

    test('混合文本', () {
      expect(
        AttachmentService.decodeXmlEntities('a &amp; b &lt;c&gt;'),
        'a & b <c>',
      );
    });

    test('无实体原样返回', () {
      expect(AttachmentService.decodeXmlEntities('plain text'), 'plain text');
    });

    test('空字符串', () {
      expect(AttachmentService.decodeXmlEntities(''), '');
    });
  });
}
