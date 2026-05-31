import 'dart:io';
import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';

/// 导入的学生数据
class ImportedStudent {
  final String name;
  final String? studentNumber;
  final String? groupName;

  ImportedStudent({required this.name, this.studentNumber, this.groupName});

  @override
  String toString() {
    return 'ImportedStudent(name: $name, studentNumber: $studentNumber, groupName: $groupName)';
  }
}

/// 导入结果
class ImportResult {
  final List<ImportedStudent> students;
  final List<String> errors;
  final int totalCount;
  final int successCount;
  final int errorCount;

  ImportResult({
    required this.students,
    required this.errors,
    required this.totalCount,
    required this.successCount,
    required this.errorCount,
  });

  String get message {
    if (errors.isNotEmpty) {
      return '导入完成：成功 $successCount 条，失败 $errorCount 条';
    }
    return '导入完成：成功 $successCount 条';
  }
}

/// 文件导入服务
class ImportService {
  /// 显示文件选择对话框并导入学生数据
  static Future<List<ImportedStudent>?> pickAndImport({
    required List<String> errorLogs,
  }) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
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

  /// 使用多编码尝试读取文件，自动识别最佳编码
  static Future<String> readFileWithAutoEncoding(File file) async {
    // 读取文件字节
    final bytes = await file.readAsBytes();

    // 1. 首先尝试 UTF-8（包括带 BOM 的 UTF-8）
    try {
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF) {
        // 有 UTF-8 BOM
        final content = utf8.decode(bytes, allowMalformed: true);
        // 移除 BOM 字符 (\u{FEFF})
        if (content.isNotEmpty && content.codeUnitAt(0) == 0xFEFF) {
          return content.substring(1);
        }
        return content;
      }

      // 没有 BOM，尝试 UTF-8
      return utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      // UTF-8 失败，尝试其他编码
    }

    // 2. 在 Windows 系统上，尝试使用 PowerShell 进行 GBK 解码
    if (Platform.isWindows) {
      try {
        return await _decodeWithPowerShell(file, bytes);
      } catch (e) {
        // PowerShell 解码失败，继续
      }
    }

    // 3. 最后尝试 Latin-1（总能成功，因为每个字节值都有效）
    return String.fromCharCodes(bytes);
  }

  /// 使用 PowerShell 解码 GBK 编码的文件
  static Future<String> _decodeWithPowerShell(
    File file,
    List<int> bytes,
  ) async {
    try {
      // 使用 PowerShell 的 [System.IO.File]::ReadAllBytes 和 GBK encoding
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '''
          \$bytes = [System.IO.File]::ReadAllBytes('${file.path.replaceAll('\\', '\\\\')}');
          \$encoding = [System.Text.Encoding]::GetEncoding(936);
          \$text = \$encoding.GetString(\$bytes);
          \$outputEncoding = [System.Text.Encoding]::UTF8;
          \$outputBytes = \$outputEncoding.GetBytes(\$text);
          \$base64 = [Convert]::ToBase64String(\$outputBytes);
          Write-Output \$base64;
          ''',
      ], stderrEncoding: utf8);

      if (result.exitCode == 0 && result.stdout != null) {
        final base64String = result.stdout.toString().trim();
        if (base64String.isNotEmpty) {
          // 解码 Base64 得到 UTF-8 字节
          final utf8Bytes = base64.decode(base64String);
          return utf8.decode(utf8Bytes, allowMalformed: true);
        }
      }
    } catch (e) {
      // PowerShell 解码失败
    }

    // 返回空字符串表示解码失败
    return '';
  }

  /// 解析CSV文件
  static Future<List<ImportedStudent>> parseCsvFile(
    String filePath,
    List<String> errorLogs,
  ) async {
    final List<ImportedStudent> students = [];
    final file = File(filePath);

    // 使用自动编码检测读取文件
    String contents;
    try {
      contents = await readFileWithAutoEncoding(file);
    } catch (e) {
      errorLogs.add('读取文件失败: $e');
      return students;
    }

    if (contents.isEmpty) {
      errorLogs.add('CSV文件为空');
      return students;
    }

    try {
      List<List<dynamic>> rows = const CsvToListConverter().convert(contents);

      if (rows.isEmpty) {
        errorLogs.add('CSV文件为空');
        return students;
      }

      // 解析表头
      final headers = _parseHeaders(rows[0]);
      final nameIdx = _findColumnIndex(headers, ['姓名', 'name', '学生姓名', '名字']);
      final studentNumberIdx = _findColumnIndex(headers, [
        '学号',
        'student_number',
        '编号',
        'ID',
      ]);
      final groupIdx = _findColumnIndex(headers, [
        '小组',
        'group',
        '分组',
        '组别',
        '所属小组',
      ]);

      // 验证必需列
      if (nameIdx == -1) {
        errorLogs.add('CSV文件中未找到"姓名"列');
        return students;
      }

      // 从第二行开始解析数据
      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];

        // 跳过空行
        if (row.isEmpty ||
            (row.length == 1 && (row[0] as String).trim().isEmpty)) {
          continue;
        }

        final name = nameIdx < row.length
            ? (row[nameIdx] as String?)?.trim() ?? ''
            : '';

        if (name.isEmpty) {
          errorLogs.add('第 ${i + 1} 行：姓名为空，已跳过');
          continue;
        }

        String? studentNumber;
        if (studentNumberIdx != -1 && studentNumberIdx < row.length) {
          final sn = (row[studentNumberIdx] as String?)?.trim() ?? '';
          if (sn.isNotEmpty) {
            studentNumber = sn;
          }
        }

        String? groupName;
        if (groupIdx != -1 && groupIdx < row.length) {
          final gn = (row[groupIdx] as String?)?.trim() ?? '';
          if (gn.isNotEmpty) {
            groupName = gn;
          }
        }

        students.add(
          ImportedStudent(
            name: name,
            studentNumber: studentNumber,
            groupName: groupName,
          ),
        );
      }
    } catch (e) {
      errorLogs.add('解析CSV文件失败: $e');
    }

    return students;
  }

  /// 解析Excel文件
  static Future<List<ImportedStudent>> parseExcelFile(
    String filePath,
    List<String> errorLogs,
  ) async {
    final List<ImportedStudent> students = [];

    try {
      final bytes = File(filePath).readAsBytesSync();
      final excel = excel_lib.Excel.decodeBytes(bytes);

      bool foundData = false;

      // 遍历所有sheet
      for (final sheet in excel.tables.keys) {
        final table = excel.tables[sheet]!;
        if (table.rows.isEmpty) continue;

        // 解析表头
        final headers = table.rows[0].map((cell) {
          if (cell == null || cell.value == null) return '';
          final raw = cell.value!;
          // CellValue needs to be converted to String first
          final strVal = raw.toString();
          return strVal.trim();
        }).toList();

        if (headers.isEmpty) continue;

        // 确保所有header都是字符串
        final normalizedHeaders = headers.map((h) => h.toString()).toList();

        final nameIdx = _findColumnIndex(normalizedHeaders, [
          '姓名',
          'name',
          '学生姓名',
          '名字',
        ]);
        final studentNumberIdx = _findColumnIndex(normalizedHeaders, [
          '学号',
          'student_number',
          '编号',
          'ID',
        ]);
        final groupIdx = _findColumnIndex(normalizedHeaders, [
          '小组',
          'group',
          '分组',
          '组别',
          '所属小组',
        ]);

        // 验证必需列
        if (nameIdx == -1) continue;

        // 从第二行开始解析数据
        for (int i = 1; i < table.rows.length; i++) {
          final row = table.rows[i];

          // 跳过空行
          if (row.isEmpty) continue;

          final nameCell = nameIdx < row.length ? row[nameIdx] : null;
          final name = _cellToString(nameCell) ?? '';

          if (name.isEmpty) {
            errorLogs.add('Sheet "$sheet" 第 ${i + 1} 行：姓名为空，已跳过');
            continue;
          }

          String? studentNumber;
          if (studentNumberIdx != -1 && studentNumberIdx < row.length) {
            final snCell = row[studentNumberIdx];
            final sn = _cellToString(snCell) ?? '';
            if (sn.isNotEmpty) {
              studentNumber = sn;
            }
          }

          String? groupName;
          if (groupIdx != -1 && groupIdx < row.length) {
            final gnCell = row[groupIdx];
            final gn = _cellToString(gnCell) ?? '';
            if (gn.isNotEmpty) {
              groupName = gn;
            }
          }

          students.add(
            ImportedStudent(
              name: name,
              studentNumber: studentNumber,
              groupName: groupName,
            ),
          );
          foundData = true;
        }
      }

      if (!foundData) {
        errorLogs.add('Excel文件中未找到有效数据');
      }
    } catch (e) {
      errorLogs.add('解析Excel文件失败: $e');
    }

    return students;
  }

  /// 辅助方法：解析表头，去除空白
  static List<String> _parseHeaders(List<dynamic> row) {
    return row.map((cell) {
      if (cell is String) return cell.trim();
      if (cell is num) return cell.toString();
      return '';
    }).toList();
  }

  /// 辅助方法：查找列索引（支持多个候选名称）
  static int _findColumnIndex(List<String> headers, List<String> candidates) {
    for (int i = 0; i < headers.length; i++) {
      final header = headers[i].toLowerCase();
      for (final candidate in candidates) {
        if (header == candidate.toLowerCase()) {
          return i;
        }
      }
    }
    return -1;
  }

  /// 辅助方法：将单元格值转为字符串
  static String? _cellToString(dynamic cell) {
    if (cell == null) return null;
    final value = cell.value;
    if (value == null) return null;
    if (value is String) return value;
    if (value is num) return value.toString();
    return value.toString();
  }
}
