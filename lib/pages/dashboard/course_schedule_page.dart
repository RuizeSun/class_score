import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../settings/course_schedule_management.dart'
    show showCourseScheduleDialog, CourseScheduleManagementView;

class CourseSchedulePage extends StatefulWidget {
  const CourseSchedulePage({super.key});

  @override
  State<CourseSchedulePage> createState() => _CourseSchedulePageState();
}

class _CourseSchedulePageState extends State<CourseSchedulePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().loadCourseSchedules();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('课程表管理')),
      body: CourseScheduleManagementView(
        onShowCourseDialog: ({Map<String, dynamic>? schedule}) =>
            showCourseScheduleDialog(context, schedule: schedule),
      ),
      // FAB is already included in CourseScheduleManagementView, no need to duplicate
    );
  }
}
