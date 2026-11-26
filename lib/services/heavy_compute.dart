import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:flutter/foundation.dart';

/// 主 isolate 之外的「重计算」工具箱。
///
/// 这里的函数只做**纯 CPU / 文件**工作：Excel 解压与 XML 解析、整库 JSON 编解码、
/// CSV 拼装、大文件 sha256。它们的共同点是耗时随数据量线性增长、动辄几十到几百
/// 毫秒——放在 UI isolate 上就是肉眼可见的掉帧（动画停、点击无响应）。
///
/// 设计约束：
/// 1. 全部是**顶层函数**（[compute] 只能跨顶层/静态函数指针，不能传闭包）；
/// 2. 入参与返回值必须**可序列化**（基本类型、List、Map、Uint8List）；
///    因此 [decodeWorkbook] 只返回「字符串表格」，不返回 Excel 对象——
///    列名识别、归一化等业务逻辑仍留在调用侧，与原地实现结果逐字一致；
/// 3. 只用于「秒级」任务。单条 SQL、单个设置读写这类毫秒级操作不要走这里，
///    isolate 的 fork 开销反而更贵；所以下面每个入口都有小数据直通分支。
///
/// 注意：数据库快照**不在**这里。`VACUUM INTO` 必须跑在应用自己那条连接上
/// （本项目未开 WAL，另开一条连接去读会被主连接的写锁挡住并抛 SQLITE_BUSY），
/// 它的「不卡提交」是靠调度解决的，见 `BackupService.scheduleBackup`。
class HeavyCompute {
  HeavyCompute._();

  /// 低于这个字节数的工作簿留在当前 isolate 解码，避免调度开销大于收益。
  static const int _minIsolateBytes = 32 * 1024;

  /// 低于这个字符数的文本/JSON 直接同步处理。
  static const int _minIsolateChars = 64 * 1024;

  // ---------------------------------------------------------------------------
  // Excel / CSV
  // ---------------------------------------------------------------------------

  /// 在后台 isolate 解码工作簿，返回 `sheetName -> rows -> cells` 的纯字符串表格。
  ///
  /// 单元格统一用 [excelCellText] 转成字符串，与旧的
  /// `cell.value?.toString() ?? ''` 逐字一致；空行保留为空 List，由调用方跳过。
  /// 保留 sheet 名是为了错误提示仍能指出是哪张表（`Sheet "x" 第 n 行`）。
  static Future<Map<String, List<List<String>>>> decodeWorkbook(
    Uint8List bytes,
  ) async {
    if (bytes.length < _minIsolateBytes) return _decodeWorkbookEntry(bytes);
    return compute(_decodeWorkbookEntry, bytes);
  }

  /// 在后台 isolate 解析 CSV 文本，返回纯字符串表格。
  ///
  /// [eol] 为空串时交由 csv 包自行识别换行；调用方负责先做 `\r\n` 归一化。
  static Future<List<List<String>>> parseCsv(
    String contents, {
    String eol = '\n',
    bool shouldParseNumbers = true,
  }) async {
    final request = _CsvRequest(contents, eol, shouldParseNumbers);
    if (contents.length < _minIsolateChars) return _parseCsvEntry(request);
    return compute(_parseCsvEntry, request);
  }

  // ---------------------------------------------------------------------------
  // JSON
  // ---------------------------------------------------------------------------

  /// 缩进美化后编码（整库导出）。
  static Future<String> encodeJsonPretty(Map<String, Object?> data) async {
    if (_roughSize(data) < _minIsolateChars) return _encodeJsonEntry(data);
    return compute(_encodeJsonEntry, data);
  }

  /// 解码整库 JSON（导入）。
  static Future<Object?> decodeJson(String text) async {
    if (text.length < _minIsolateChars) return jsonDecode(text);
    return compute(_decodeJsonEntry, text);
  }

  // ---------------------------------------------------------------------------
  // 导出 / 校验
  // ---------------------------------------------------------------------------

  /// 把评分记录拼成 CSV 文本（含表头，排除 `id` 列）。
  ///
  /// 与旧实现同规则：表头取第一条记录的键顺序，逐行按 `,` 连接；
  /// 记录为空返回空串（调用方据此不写只有表头的文件）。
  static Future<String> buildScoresCsv(
    List<Map<String, Object?>> records,
  ) async {
    if (records.isEmpty) return '';
    if (records.length * 16 < _minIsolateChars) {
      return _buildScoresCsvEntry(records);
    }
    return compute(_buildScoresCsvEntry, records);
  }

  /// 计算文件的 sha256（十六进制小写）。
  ///
  /// 流式读取，不把整个安装包一次性载入内存；在后台 isolate 里跑，
  /// 下载完成后的校验不再冻住界面。
  static Future<String> fileSha256(String path) =>
      compute(_fileSha256Entry, path);

  /// 粗略估算可序列化数据的体量（只用于决定是否值得换 isolate）。
  static int _roughSize(Object? value) {
    if (value is String) return value.length;
    if (value is List) {
      var total = 0;
      for (final item in value) {
        total += _roughSize(item);
      }
      return total;
    }
    if (value is Map) {
      var total = 0;
      for (final entry in value.entries) {
        total += _roughSize(entry.key) + _roughSize(entry.value);
      }
      return total;
    }
    return 16;
  }
}

// -----------------------------------------------------------------------------
// isolate 入口（必须是顶层函数）
// -----------------------------------------------------------------------------

/// 单个单元格的字符串化规则。
///
/// 与 `ImportService._cellToString` / `ScheduleImportService._cellToString`
/// 对 Excel 单元格的处理一致（`null` → 空串，其余 `toString()`）。
@visibleForTesting
String excelCellText(excel_lib.Data? cell) {
  final value = cell?.value;
  if (value == null) return '';
  return value.toString();
}

Map<String, List<List<String>>> _decodeWorkbookEntry(Uint8List bytes) {
  final excel = excel_lib.Excel.decodeBytes(bytes);
  final tables = <String, List<List<String>>>{};
  for (final name in excel.tables.keys) {
    final table = excel.tables[name]!;
    tables[name] = [
      for (final row in table.rows) [for (final cell in row) excelCellText(cell)],
    ];
  }
  return tables;
}

class _CsvRequest {
  const _CsvRequest(this.contents, this.eol, this.shouldParseNumbers);

  final String contents;
  final String eol;

  /// 是否把未加引号的文本自动转成数字。
  ///
  /// 学生花名册必须为 false：csv 包会把学号 "01" 解析成 int 1，
  /// 前导零丢失、"1.50" 变成 1.5——导回去的学号就与文件不一致了。
  final bool shouldParseNumbers;
}

List<List<String>> _parseCsvEntry(_CsvRequest request) {
  final rows = CsvToListConverter(
    eol: request.eol.isEmpty ? null : request.eol,
    shouldParseNumbers: request.shouldParseNumbers,
  ).convert(request.contents);
  return [
    for (final row in rows)
      [for (final cell in row) cell == null ? '' : cell.toString()],
  ];
}

String _encodeJsonEntry(Map<String, Object?> data) =>
    const JsonEncoder.withIndent('  ').convert(data);

Object? _decodeJsonEntry(String text) => jsonDecode(text);

String _buildScoresCsvEntry(List<Map<String, Object?>> records) {
  if (records.isEmpty) return '';
  final headers = records.first.keys.where((k) => k != 'id').toList();
  final buffer = StringBuffer()..writeln(headers.join(','));
  for (final record in records) {
    buffer.writeln(headers.map((h) => '${record[h] ?? ''}').join(','));
  }
  return buffer.toString();
}

Future<String> _fileSha256Entry(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}
