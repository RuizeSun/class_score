class Group {
  final int? id;
  final String name;

  Group({this.id, required this.name});

  Map<String, dynamic> toMap() {
    return {if (id != null) 'id': id, 'name': name};
  }

  factory Group.fromMap(Map<String, dynamic> map) {
    return Group(id: map['id'] as int?, name: map['name'] as String);
  }
}
