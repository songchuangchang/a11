// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:aichat/services/regression_test_service.dart';

/// RegressionTestService.matchExpectedContent 单元测试
///
/// 这是回归测试的核心判定函数：给定 AI 的回复和期望内容（"12345678"），
/// 判定回复是否符合预期。覆盖：
///   - 完全相等
///   - 包含期望内容（连写）
///   - 数字字符相等（允许分隔符如空格/破折号/逗号）
///   - 数字字符包含期望（OCR/拆字兜底）
///   - 缺失/多余数字
///   - 空回复 / 全空格
///   - 完全无关内容
///   - 触发反问关键词列表完整性
void main() {
  const expected = RegressionTestService.kExpectedContent; // '12345678'

  group('matchExpectedContent - 通过场景', () {
    test('完全相等', () {
      expect(RegressionTestService.matchExpectedContent('12345678', expected),
          isTrue);
    });

    test('完全相等（带空格 trim）', () {
      expect(
          RegressionTestService.matchExpectedContent('  12345678  ', expected),
          isTrue);
    });

    test('包含期望内容（中文夹带）', () {
      expect(
          RegressionTestService.matchExpectedContent(
              '图片里写的数字是 12345678。', expected),
          isTrue);
    });

    test('包含期望内容（英文夹带）', () {
      expect(
          RegressionTestService.matchExpectedContent(
              'The number is 12345678.', expected),
          isTrue);
    });

    test('数字带空格分隔', () {
      expect(
          RegressionTestService.matchExpectedContent('1 2 3 4 5 6 7 8', expected),
          isTrue);
    });

    test('数字带破折号分隔', () {
      expect(
          RegressionTestService.matchExpectedContent('1-2-3-4-5-6-7-8', expected),
          isTrue);
    });

    test('数字带逗号分隔', () {
      expect(
          RegressionTestService.matchExpectedContent('1,2,3,4,5,6,7,8', expected),
          isTrue);
    });

    test('数字带中文逗号分隔', () {
      expect(
          RegressionTestService.matchExpectedContent(
              '1，2，3，4，5，6，7，8', expected),
          isTrue);
    });

    test('数字混入其他文字（句子里）', () {
      expect(
          RegressionTestService.matchExpectedContent(
              '我识别到 1 2 3 4 5 6 7 8 共 8 个数字', expected),
          isTrue);
    });

    test('回复里含 9 位数字但前缀匹配（OCR 多识别 0）', () {
      // 这种情况规则 4 兜底命中
      expect(
          RegressionTestService.matchExpectedContent('012345678', expected),
          isTrue);
    });
  });

  group('matchExpectedContent - 失败场景', () {
    test('空字符串', () {
      expect(RegressionTestService.matchExpectedContent('', expected), isFalse);
    });

    test('全空格', () {
      expect(
          RegressionTestService.matchExpectedContent('   ', expected), isFalse);
    });

    test('完全无关内容', () {
      expect(RegressionTestService.matchExpectedContent('hello world', expected),
          isFalse);
    });

    test('只有一个数字', () {
      expect(RegressionTestService.matchExpectedContent('1', expected), isFalse);
    });

    test('缺一个数字', () {
      expect(RegressionTestService.matchExpectedContent('1234567', expected),
          isFalse);
    });

    test('数字乱序', () {
      expect(RegressionTestService.matchExpectedContent('87654321', expected),
          isFalse);
    });

    test('部分匹配（只有前 4 位）', () {
      expect(
          RegressionTestService.matchExpectedContent(
              '看到 1234', expected),
          isFalse);
    });

    test('全是相同数字但不全', () {
      expect(
          RegressionTestService.matchExpectedContent('11111111', expected),
          isFalse);
    });
  });

  group('matchExpectedContent - 边界场景', () {
    test('换行符分隔', () {
      // 数字字符相同，规则 3 命中
      expect(
          RegressionTestService.matchExpectedContent(
              '1\n2\n3\n4\n5\n6\n7\n8', expected),
          isTrue);
    });

    test('带 Markdown 格式包裹', () {
      // "**12345678**" 规则 2 命中
      expect(
          RegressionTestService.matchExpectedContent('**12345678**', expected),
          isTrue);
    });

    test('代码块包裹', () {
      expect(
          RegressionTestService.matchExpectedContent(
              '```\n12345678\n```', expected),
          isTrue);
    });

    test('只有数字字符相等的复杂场景', () {
      // "数字 1，数字 2，...数字 8" 这种表述
      expect(
          RegressionTestService.matchExpectedContent(
              '识别结果是 数字 1 数字 2 数字 3 数字 4 数字 5 数字 6 数字 7 数字 8',
              expected),
          isTrue);
    });
  });

  group('kRebuttalTriggers 触发反问关键词列表', () {
    test('列表非空', () {
      expect(RegressionTestService.kRebuttalTriggers, isNotEmpty);
    });

    test('包含 "测试反问" 关键词', () {
      expect(RegressionTestService.kRebuttalTriggers, contains('测试反问'));
    });

    test('所有关键词非空字符串', () {
      for (final kw in RegressionTestService.kRebuttalTriggers) {
        expect(kw.trim().isNotEmpty, isTrue,
            reason: '关键词 "$kw" 是空字符串');
      }
    });
  });

  group('kExpectedContent 固定期望内容', () {
    test('内容为 "12345678"', () {
      expect(RegressionTestService.kExpectedContent, '12345678');
    });

    test('长度 8', () {
      expect(RegressionTestService.kExpectedContent.length, 8);
    });
  });
}
