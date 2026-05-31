class ScoreItem {
  final int? id;
  final String name;
  final double defaultScore;
  final String description;

  ScoreItem({
    this.id,
    required this.name,
    required this.defaultScore,
    this.description = '',
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'default_score': defaultScore,
      'description': description,
    };
  }

  factory ScoreItem.fromMap(Map<String, dynamic> map) {
    return ScoreItem(
      id: map['id'] as int?,
      name: map['name'] as String,
      defaultScore: (map['default_score'] as num).toDouble(),
      description: map['description'] as String? ?? '',
    );
  }
}
