import 'package:flutter/material.dart';
import '../../models/student.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('学生管理')),
      body: StudentManagementView(
        onShowStudentDialog: ({Student? student}) =>
            showStudentDialog(context, student: student),
      ),
      // 导入 / 添加按钮已包含在 StudentManagementView 的工具栏中
    );
  }
}
