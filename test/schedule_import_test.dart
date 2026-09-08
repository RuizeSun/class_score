import 'dart:io';

import 'package:class_score/services/schedule_import_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScheduleImportService.parseWeekday', () {
    test('解析中文星期', () {
      expect(ScheduleImportService.parseWeekday('周一'), 1);
      expect(ScheduleImportService.parseWeekday('星期三'), 3);
      expect(ScheduleImportService.parseWeekday('礼拜五'), 5);
      expect(ScheduleImportService.parseWeekday('周日'), 7);
      expect(ScheduleImportService.parseWeekday('六'), 6);
      expect(ScheduleImportService.parseWeekday('星期天'), 7);
    });

    test('解析数字', () {
      expect(ScheduleImportService.parseWeekday('1'), 1);
      expect(ScheduleImportService.parseWeekday('7'), 7);
      expect(ScheduleImportService.parseWeekday('0'), isNull);
      expect(ScheduleImportService.parseWeekday('8'), isNull);
    });

    test('解析英文', () {
      expect(ScheduleImportService.parseWeekday('Monday'), 1);
      expect(ScheduleImportService.parseWeekday('MON'), 1);
      expect(ScheduleImportService.parseWeekday('wed'), 3);
      expect(ScheduleImportService.parseWeekday('Sunday'), 7);
    });

    test('无法识别时返回 null', () {
      expect(ScheduleImportService.parseWeekday(''), isNull);
      expect(ScheduleImportService.parseWeekday('abc'), isNull);
    });
  });

  group('ScheduleImportService.parseScheduleTime', () {
    test('归一化为 HH:mm', () {
      expect(ScheduleImportService.parseScheduleTime('8'), '08:00');
      expect(ScheduleImportService.parseScheduleTime('8:0'), '08:00');
      expect(ScheduleImportService.parseScheduleTime('08:00'), '08:00');
      expect(ScheduleImportService.parseScheduleTime('08:00:00'), '08:00');
      expect(ScheduleImportService.parseScheduleTime('800'), '08:00');
      expect(ScheduleImportService.parseScheduleTime('0940'), '09:40');
      expect(ScheduleImportService.parseScheduleTime('8.30'), '08:30');
      expect(ScheduleImportService.parseScheduleTime('8时30分'), '08:30');
      expect(ScheduleImportService.parseScheduleTime('８：００'), '08:00');
    });

    test('非法时间返回 null', () {
      expect(ScheduleImportService.parseScheduleTime(''), isNull);
      expect(ScheduleImportService.parseScheduleTime('abc'), isNull);
      expect(ScheduleImportService.parseScheduleTime('25:00'), isNull);
      expect(ScheduleImportService.parseScheduleTime('8:70'), isNull);
    });
  });

  group('ScheduleImportService.parseCsvFile', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('schedule_import_test');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<String> writeCsv(String content) async {
      final file = File('${tempDir.path}${Platform.pathSeparator}schedule.csv');
      await file.writeAsString(content);
      return file.path;
    }

    test('解析标准课程表 CSV', () async {
      final path = await writeCsv(
        '星期,课程名称,开始时间,结束时间\n'
        '周一,数学,8:00,9:40\n'
        '星期三,英语,10:00,11:40\n'
        '7,班会,14:00,14:40\n',
      );

      final errors = <String>[];
      final result = await ScheduleImportService.parseCsvFile(path, errors);

      expect(errors, isEmpty);
      expect(result.length, 3);
      expect(result[0].weekday, 1);
      expect(result[0].courseName, '数学');
      expect(result[0].startTime, '08:00');
      expect(result[0].endTime, '09:40');
      expect(result[1].weekday, 3);
      expect(result[2].weekday, 7);
      expect(result[2].courseName, '班会');
    });

    test('跳过非法行并记录错误', () async {
      final path = await writeCsv(
        '星期,课程名称,开始时间,结束时间\n'
        '周一,数学,8:00,9:40\n'
        '星期八,语文,10:00,11:40\n'
        '周二,,10:00,11:40\n'
        '周三,英语,11:40,10:00\n'
        '周四,物理,abc,10:00\n',
      );

      final errors = <String>[];
      final result = await ScheduleImportService.parseCsvFile(path, errors);

      expect(result.length, 1);
      expect(result.first.courseName, '数学');
      expect(errors.length, 4);
    });

    test('缺少必需列时报错', () async {
      final path = await writeCsv('星期,课程名称\n周一,数学\n');

      final errors = <String>[];
      final result = await ScheduleImportService.parseCsvFile(path, errors);

      expect(result, isEmpty);
      expect(errors, isNotEmpty);
      expect(errors.first, contains('未找到必需的列'));
    });
  });
}
