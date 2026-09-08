import 'dart:io';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import 'import_service.dart';

/// 导入的单条课程安排
class ImportedSchedule {
  final int weekday; // 1-7 (Monday=1, Sunday=7)
  final String courseName;
  final String startTime; // HH:mm
  final String endTime; // HH:mm

  ImportedSchedule({
    required this.weekday,
    required this.courseName,
    required this.startTime,
    required this.endTime,
  });

  Map<String, dynamic> toMap() {
    return {
      'weekday': weekday,
      'course_name': courseName,
      'start_time': startTime,
      'end_time': endTime,
    };
  }

  @override
  String toString() {
    return 'ImportedSchedule(weekday: $weekday, courseName: $courseName, '
        'startTime: $startTime, endTime: $endTime)';
  }
}

/// 课程表导入结果
class ScheduleImportResult {
  final List<ImportedSchedule> schedules;
  final List<String> errors;

  ScheduleImportResult({required this.schedules, required this.errors});

  int get successCount => schedules.length;
  int get errorCount => errors.length;
}

/// 课程表文件导入服务
///
/// 支持的表格列（表头可模糊匹配）：
/// - 星期：星期 / 周几 / weekday / 1~7 / 周一 / Monday
/// - 课程名称：课程名称 / 课程名 / 课程 / 科目 / course
/// - 开始时间：开始时间 / 开始 / start（支持 8、800、8:00、08:00:00）
/// - 结束时间：结束时间 / 结束 / end
class ScheduleImportService {
  /// 星期别名
  static const Map<String, int> _weekdayAliases = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '日': 7,
    '天': 7,
    'mon': 1,
    'monday': 1,
    'tue': 2,
    'tues': 2,
    'tuesday': 2,
    'wed': 3,
    'wednesday': 3,
    'thu': 4,
    'thur': 4,
    'thurs': 4,
    'thursday': 4,
    'fri': 5,
    'friday': 5,
    'sat': 6,
    'saturday': 6,
    'sun': 7,
    'sunday': 7,
  };

  /// 选择文件并解析课程表数据。
  /// 返回 null 表示用户取消了选择。
  static Future<List<ImportedSchedule>?> pickAndImport({
    required List<String> errorLogs,
  }) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'xls'],
    );

    if (result == null) return null;

    final filePath = result.files.single.path!;
    final fileName = result.files.single.name.toLowerCase();

    if (fileName.endsWith('.csv')) {
      return await parseCsvFile(filePath, errorLogs);
    } else if (fileName.endsWith('.xlsx') || fileName.endsWith('.xls')) {
      return await parseExcelFile(filePath, errorLogs);
    } else {
      errorLogs.add('不支持的文件格式');
      return null;
    }
  }

  /// 解析 CSV 文件（自动识别 UTF-8 / GBK 编码）
  static Future<List<ImportedSchedule>> parseCsvFile(
    String filePath,
    List<String> errorLogs,
  ) async {
    final List<ImportedSchedule> schedules = [];
    final file = File(filePath);

    String contents;
    try {
      contents = await ImportService.readFileWithAutoEncoding(file);
    } catch (e) {
      errorLogs.add('读取文件失败: $e');
      return schedules;
    }

    if (contents.trim().isEmpty) {
      errorLogs.add('CSV文件为空');
      return schedules;
    }

    try {
      // 统一换行符，兼容 Windows(\r\n) 与 Unix(\n)
      final normalized = contents.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      final List<List<dynamic>> rows = CsvToListConverter(
        eol: '\n',
      ).convert(normalized);

      if (rows.isEmpty) {
        errorLogs.add('CSV文件为空');
        return schedules;
      }

      final headers = _parseHeaders(rows[0]);
      final columns = _resolveColumns(headers);
      if (columns == null) {
        errorLogs.add('CSV文件中未找到必需的列：需要"星期""课程名称""开始时间""结束时间"');
        return schedules;
      }

      for (int i = 1; i < rows.length; i++) {
        _appendRow(rows[i], columns, i + 1, 'CSV', schedules, errorLogs);
      }
    } catch (e) {
      errorLogs.add('解析CSV文件失败: $e');
    }

    if (schedules.isEmpty && errorLogs.isEmpty) {
      errorLogs.add('CSV文件中未找到有效的课程数据');
    }

    return schedules;
  }

  /// 解析 Excel 文件
  static Future<List<ImportedSchedule>> parseExcelFile(
    String filePath,
    List<String> errorLogs,
  ) async {
    final List<ImportedSchedule> schedules = [];

    try {
      final bytes = File(filePath).readAsBytesSync();
      final excel = excel_lib.Excel.decodeBytes(bytes);

      bool foundSheet = false;

      for (final sheet in excel.tables.keys) {
        final table = excel.tables[sheet]!;
        if (table.rows.isEmpty) continue;

        final headers = _parseHeaders(
          table.rows[0].map((cell) => _cellToString(cell) ?? '').toList(),
        );
        final columns = _resolveColumns(headers);
        if (columns == null) continue;

        foundSheet = true;

        for (int i = 1; i < table.rows.length; i++) {
          _appendRow(
            table.rows[i],
            columns,
            i + 1,
            'Sheet "$sheet"',
            schedules,
            errorLogs,
          );
        }
      }

      if (!foundSheet) {
        errorLogs.add('Excel文件中未找到包含"星期""课程名称""开始时间""结束时间"列的工作表');
      } else if (schedules.isEmpty && errorLogs.isEmpty) {
        errorLogs.add('Excel文件中未找到有效的课程数据');
      }
    } catch (e) {
      errorLogs.add('解析Excel文件失败: $e');
    }

    return schedules;
  }

  /// 解析星期，支持：周一 / 星期一 / 礼拜一 / 1 / 一 / Mon / Monday
  static int? parseWeekday(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;

    // 纯数字
    final direct = int.tryParse(s);
    if (direct != null) {
      return (direct >= 1 && direct <= 7) ? direct : null;
    }

    // 直接匹配别名（含英文全称/缩写）
    final directAlias = _weekdayAliases[s];
    if (directAlias != null) return directAlias;

    // 去掉常见前缀后再次匹配
    s = s
        .replaceAll('星期', '')
        .replaceAll('礼拜', '')
        .replaceAll('周', '')
        .replaceAll(RegExp(r'[\s\.]'), '');
    if (s.isEmpty) return null;

    final numeric = int.tryParse(s);
    if (numeric != null) {
      return (numeric >= 1 && numeric <= 7) ? numeric : null;
    }

    final alias = _weekdayAliases[s];
    if (alias != null) return alias;

    // 兜底：字符串中包含 1~7 的数字
    final match = RegExp(r'[1-7]').firstMatch(s);
    if (match != null) return int.tryParse(match.group(0)!);

    return null;
  }

  /// 解析时间并归一化为 HH:mm。
  /// 支持：8 / 8:0 / 08:00 / 08:00:00 / 8时30分 / 全角冒号 / 8.30
  static String? parseScheduleTime(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;

    // 统一全角字符
    s = s
        .replaceAll('：', ':')
        .replaceAll('．', '.')
        .replaceAll('。', '.')
        .replaceAll('时', ':')
        .replaceAll('点', ':')
        .replaceAll('分', '')
        .trim();

    // 全角数字转半角
    s = s.replaceAllMapped(
      RegExp(r'[\uFF10-\uFF19]'),
      (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFF10 + 0x30),
    );

    int? hour;
    int? minute;

    if (s.contains(':')) {
      final parts = s.split(':');
      hour = int.tryParse(parts[0].trim());
      minute = parts.length > 1 ? int.tryParse(parts[1].trim()) : 0;
    } else if (s.contains('.')) {
      final parts = s.split('.');
      hour = int.tryParse(parts[0].trim());
      final minuteText = parts.length > 1 ? parts[1].trim() : '';
      minute = minuteText.isEmpty ? 0 : int.tryParse(minuteText);
    } else {
      final digits = s.replaceAll(RegExp(r'\D'), '');
      if (digits.length == 3) {
        hour = int.tryParse(digits.substring(0, 1));
        minute = int.tryParse(digits.substring(1));
      } else if (digits.length == 4) {
        hour = int.tryParse(digits.substring(0, 2));
        minute = int.tryParse(digits.substring(2));
      } else if (digits.isNotEmpty && digits.length <= 2) {
        hour = int.tryParse(digits);
        minute = 0;
      }
    }

    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }


  // ---- 内部辅助 ----

  static void _appendRow(
    List<dynamic> row,
    _ScheduleColumns columns,
    int lineNumber,
    String source,
    List<ImportedSchedule> out,
    List<String> errorLogs,
  ) {
    String cellAt(int index) {
      if (index < 0 || index >= row.length) return '';
      return (_cellToString(row[index]) ?? '').trim();
    }

    final weekdayRaw = cellAt(columns.weekday);
    final name = cellAt(columns.name);
    final startRaw = cellAt(columns.start);
    final endRaw = cellAt(columns.end);

    // 跳过完全空行
    if (weekdayRaw.isEmpty &&
        name.isEmpty &&
        startRaw.isEmpty &&
        endRaw.isEmpty) {
      return;
    }

    final weekday = parseWeekday(weekdayRaw);
    if (weekday == null) {
      errorLogs.add('$source 第 $lineNumber 行：无法识别星期"$weekdayRaw"，已跳过');
      return;
    }

    if (name.isEmpty) {
      errorLogs.add('$source 第 $lineNumber 行：课程名称为空，已跳过');
      return;
    }

    final start = parseScheduleTime(startRaw);
    if (start == null) {
      errorLogs.add('$source 第 $lineNumber 行：开始时间"$startRaw"格式不正确，已跳过');
      return;
    }

    final end = parseScheduleTime(endRaw);
    if (end == null) {
      errorLogs.add('$source 第 $lineNumber 行：结束时间"$endRaw"格式不正确，已跳过');
      return;
    }

    if (end.compareTo(start) <= 0) {
      errorLogs.add('$source 第 $lineNumber 行：结束时间需晚于开始时间，已跳过');
      return;
    }

    out.add(
      ImportedSchedule(
        weekday: weekday,
        courseName: name,
        startTime: start,
        endTime: end,
      ),
    );
  }

  static _ScheduleColumns? _resolveColumns(List<String> headers) {
    final weekday = _findColumnIndex(headers, [
      '星期',
      '星期几',
      '周几',
      'weekday',
      'week',
      'day',
    ]);
    final name = _findColumnIndex(headers, [
      '课程名称',
      '课程名',
      '课程',
      '科目',
      '名称',
      'course',
      'course_name',
      'subject',
      'name',
    ]);
    final start = _findColumnIndex(headers, [
      '开始时间',
      '开始',
      '起始时间',
      '开始时刻',
      'start',
      'start_time',
    ]);
    final end = _findColumnIndex(headers, [
      '结束时间',
      '结束',
      '终止时间',
      '结束时刻',
      'end',
      'end_time',
    ]);

    if (weekday == -1 || name == -1 || start == -1 || end == -1) {
      return null;
    }

    return _ScheduleColumns(
      weekday: weekday,
      name: name,
      start: start,
      end: end,
    );
  }


  /// 解析表头，去除空白
  static List<String> _parseHeaders(List<dynamic> row) {
    return row.map((cell) {
      if (cell is String) return cell.trim();
      if (cell is num) return cell.toString();
      return '';
    }).toList();
  }

  /// 查找列索引（先精确匹配，再包含匹配）
  static int _findColumnIndex(List<String> headers, List<String> candidates) {
    final normalized = headers.map((h) => h.toLowerCase().trim()).toList();
    for (int i = 0; i < normalized.length; i++) {
      for (final candidate in candidates) {
        if (normalized[i] == candidate.toLowerCase()) {
          return i;
        }
      }
    }
    for (int i = 0; i < normalized.length; i++) {
      for (final candidate in candidates) {
        if (normalized[i].contains(candidate.toLowerCase())) {
          return i;
        }
      }
    }
    return -1;
  }

  /// 将单元格值转为字符串（兼容 CSV 原始值与 Excel CellValue）
  static String? _cellToString(dynamic cell) {
    if (cell == null) return null;
    if (cell is String) return cell;
    if (cell is num) return cell.toString();
    if (cell is bool) return cell.toString();
    try {
      final value = cell.value; // Excel CellValue
      if (value == null) return null;
      return value.toString();
    } catch (_) {
      return cell.toString();
    }
  }
}

class _ScheduleColumns {
  final int weekday;
  final int name;
  final int start;
  final int end;

  const _ScheduleColumns({
    required this.weekday,
    required this.name,
    required this.start,
    required this.end,
  });
}

