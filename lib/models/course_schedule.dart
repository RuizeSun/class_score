class CourseSchedule {
  final int? id;
  final int weekday; // 1-7 (Monday=1, Sunday=7)
  final String courseName;
  final String startTime; // HH:mm
  final String endTime; // HH:mm

  CourseSchedule({
    this.id,
    required this.weekday,
    required this.courseName,
    required this.startTime,
    required this.endTime,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'weekday': weekday,
      'course_name': courseName,
      'start_time': startTime,
      'end_time': endTime,
    };
  }

  factory CourseSchedule.fromMap(Map<String, dynamic> map) {
    return CourseSchedule(
      id: map['id'] as int?,
      weekday: map['weekday'] as int,
      courseName: map['course_name'] as String,
      startTime: map['start_time'] as String,
      endTime: map['end_time'] as String,
    );
  }
}
