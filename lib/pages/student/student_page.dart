import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/student.dart';
import '../../providers/student_provider.dart';
import '../../providers/auth_provider.dart';
import '../settings/student_management.dart'
    show showStudentDialog, StudentManagementView;

class StudentPage extends StatefulWidget {
  const StudentPage({super.key});

  @override
  State<StudentPage> createState() => _StudentPageState();
}

class _StudentPageState extends State<StudentPage> {
  @override
  Widget build(BuildContext context) {
    final isUnlocked = context.watch<AuthProvider>().isUnlocked;

    return Scaffold(
      appBar: AppBar(
        title: const Text('学生管理'),
        actions: [
          if (isUnlocked)
            PopupMenuButton(
              icon: const Icon(Icons.file_download),
              tooltip: '导入学生',
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'csv',
                  child: Row(
                    children: [
                      Icon(Icons.file_download_outlined),
                      SizedBox(width: 8),
                      Text('从 CSV 导入'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'excel',
                  child: Row(
                    children: [
                      Icon(Icons.file_download_outlined),
                      SizedBox(width: 8),
                      Text('从 Excel 导入'),
                    ],
                  ),
                ),
              ],
              onSelected: (value) async {
                if (value == 'csv' || value == 'excel') {
                  await StudentProvider.showImportDialog(context);
                }
              },
            ),
        ],
      ),
      body: StudentManagementView(
        onShowStudentDialog: ({Student? student}) =>
            showStudentDialog(context, student: student),
      ),
      floatingActionButton: isUnlocked
          ? FloatingActionButton(
              onPressed: () => showStudentDialog(context),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
