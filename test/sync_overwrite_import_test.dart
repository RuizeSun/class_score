import 'dart:io';

import 'package:class_score/database/database_helper.dart';
import 'package:class_score/services/import_service.dart';
import 'package:class_score/providers/student_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// 覆盖导入：v11 之后旧行变成墓碑而不是消失，导入必须仍然"能进得去"。
///
/// 这条路径的失败特别隐蔽：导入循环里每行都包了 try/catch，撞唯一索引时
/// 异常被吞掉，界面只会显示"成功导入 0 人"，没有任何报错。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cs_import');
    DatabaseHelper.dbDirOverride = root.path;
  });

  tearDown(() async {
    await DatabaseHelper.instance.closeDatabase();
    DatabaseHelper.dbDirOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('覆盖导入：同一批学号重导一遍仍然全部成功', () async {
    final provider = StudentProvider();
    final batch = <ImportedStudent>[
      ImportedStudent(name: '张三', studentNumber: '01', groupName: '一班'),
      ImportedStudent(name: '李四', studentNumber: '02', groupName: '一班'),
    ];

    expect(await provider.batchImportStudents(importedStudents: batch), 2);
    expect((await DatabaseHelper.instance.getStudents()), hasLength(2));

    // 同样的学号再覆盖导入一次：旧行变成墓碑，新行必须能落库
    final again = await provider.batchImportStudents(
      importedStudents: batch,
      overwrite: true,
    );
    expect(again, 2, reason: '覆盖导入不能因为墓碑占着唯一索引而整批失败');

    final students = await DatabaseHelper.instance.getStudents();
    expect(students, hasLength(2), reason: '旧的墓碑行不该出现在列表里');
    expect(
      students.map((s) => s['student_number']).toSet(),
      {'01', '02'},
    );
  });
}
