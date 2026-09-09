class Student {
  final int? id;
  final String name;
  final String studentNumber;
  // groupId can be null to represent "未分组"
  final int? groupId;
  // 是否参与其所在小组的总分统计（默认 true）
  final bool includeInGroupTotal;

  Student({
    this.id,
    required this.name,
    required this.studentNumber,
    this.groupId,
    this.includeInGroupTotal = true,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'student_number': studentNumber,
      if (groupId != null) 'group_id': groupId,
      'include_in_group_total': includeInGroupTotal ? 1 : 0,
    };
  }

  factory Student.fromMap(Map<String, dynamic> map) {
    return Student(
      id: map['id'] as int?,
      name: map['name'] as String,
      studentNumber: (map['student_number'] as String?) ?? '',
      groupId: map['group_id'] as int?,
      includeInGroupTotal:
          ((map['include_in_group_total'] as int?) ?? 1) == 1,
    );
  }
}
