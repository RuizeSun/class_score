import 'dart:convert';
import 'dart:typed_data';

import 'package:class_score/services/heavy_compute.dart';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:flutter_test/flutter_test.dart';

/// `HeavyCompute` 把重活搬到后台 isolate，但**结果必须与原来的同步实现逐字一致**。
/// 这里用「同一份输入分别走两条路径再对比」的方式把等价性钉死：
/// 以后有人改 isolate 侧实现，测试会直接指出差异。
void main() {
  group('HeavyCompute.parseCsv', () {
    test('与 CsvToListConverter 结果一致（含空单元格与数字）', () async {
      const contents = '姓名,学号,小组\r\n张三,01,一组\r\n\r\n李四,,二组\r\n';
      final expected = const CsvToListConverter().convert(contents);
      final actual = await HeavyCompute.parseCsv(contents, eol: '');

      expect(actual.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        expect(
          actual[i],
          expected[i].map((cell) => cell == null ? '' : cell.toString()).toList(),
          reason: '第 $i 行应与同步解析一致',
        );
      }
    });

    test('shouldParseNumbers: false 保留学号前导零与小数位（花名册路径）', () async {
      const contents = '姓名,学号\r\n张三,01\r\n李四,1.50\r\n王五,007abc\r\n';
      final rows = await HeavyCompute.parseCsv(
        contents,
        eol: '',
        shouldParseNumbers: false,
      );

      expect(rows[1], ['张三', '01']);
      expect(rows[2], ['李四', '1.50']);
      expect(rows[3], ['王五', '007abc']);
      // 对照：默认（解析数字）会把它们变成 1 / 1.5 —— 学号就此与花名册不一致。
      final parsed = await HeavyCompute.parseCsv(contents, eol: '');
      expect(parsed[1][1], '1');
      expect(parsed[2][1], '1.5');
    });

    test('空文本返回空表', () async {
      expect(await HeavyCompute.parseCsv('', eol: ''), isEmpty);
    });

    test('eol 显式传 \\n 时按 LF 切行（课表导入走这条路径）', () async {
      const contents = '星期,课程名称\n周一,数学\n周三,英语\n';
      final rows = await HeavyCompute.parseCsv(contents, eol: '\n');
      expect(rows.length, 3);
      expect(rows.first, ['星期', '课程名称']);
      expect(rows.last, ['周三', '英语']);
    });

    test('大文本走 isolate 分支，结果与小文本分支一致', () async {
      // 制造一个超过阈值（64KB）的 CSV，确保真的经过 compute 分支。
      final buffer = StringBuffer('姓名,学号\r\n');
      for (var i = 0; i < 8000; i++) {
        buffer.write('学生$i,${i.toString().padLeft(4, '0')}\r\n');
      }
      final contents = buffer.toString();
      expect(contents.length, greaterThan(64 * 1024));

      final rows = await HeavyCompute.parseCsv(contents, eol: '');
      expect(rows.length, 8001);
      expect(rows.first, ['姓名', '学号']);
      expect(rows.last, ['学生7999', '7999']);
    });
  });

  group('HeavyCompute.encodeJsonPretty / decodeJson', () {
    test('缩进风格与 JsonEncoder.withIndent 一致', () async {
      final data = <String, Object?>{
        'groups': [
          {'id': 1, 'name': '第一组'},
        ],
        'export_time': '2026-01-01T00:00:00.000',
      };
      final encoded = await HeavyCompute.encodeJsonPretty(data);
      expect(encoded, const JsonEncoder.withIndent('  ').convert(data));
    });

    test('编码后再解码可还原', () async {
      final data = <String, Object?>{
        'students': [
          {'id': 7, 'name': '张三', 'student_number': '01'},
        ],
      };
      final text = await HeavyCompute.encodeJsonPretty(data);
      final decoded = await HeavyCompute.decodeJson(text) as Map<String, dynamic>;
      expect(decoded, data);
    });
  });

  group('HeavyCompute.buildScoresCsv', () {
    test('表头取首条记录的键顺序并排除 id', () async {
      final csv = await HeavyCompute.buildScoresCsv([
        {'id': 1, 'score': 2, 'reason': '作业'},
        {'id': 2, 'score': -1, 'reason': '迟到'},
      ]);
      final lines = csv.trim().split('\n');
      expect(lines.first, 'score,reason');
      expect(lines[1], '2,作业');
      expect(lines[2], '-1,迟到');
    });

    test('记录为空时返回空串（不写只有表头的文件）', () async {
      expect(await HeavyCompute.buildScoresCsv(const []), '');
    });
  });

  group('HeavyCompute.decodeWorkbook', () {
    test('返回 sheet 名与字符串表格，与逐格 toString 一致', () async {
      final workbook = excel_lib.Excel.createExcel();
      final sheet = workbook['成绩'];
      sheet.appendRow([
        excel_lib.TextCellValue('姓名'),
        excel_lib.TextCellValue('学号'),
      ]);
      sheet.appendRow([
        excel_lib.TextCellValue('张三'),
        excel_lib.IntCellValue(12),
      ]);
      final bytes = Uint8List.fromList(workbook.encode()!);

      final tables = await HeavyCompute.decodeWorkbook(bytes);
      // 默认是否存在一个空 sheet 取决于 excel 包实现，只断言我们要的那个
      final rows = tables['成绩'];
      expect(rows, isNotNull);
      expect(rows!.first, ['姓名', '学号']);
      expect(rows[1], ['张三', '12']);
    });

    test('excelCellText 对空单元格返回空串', () {
      expect(excelCellText(null), '');
    });
  });
}
