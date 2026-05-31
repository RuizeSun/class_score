class UsbKey {
  final int? id;
  final String token;
  final String label;
  final String createdAt;

  UsbKey({
    this.id,
    required this.token,
    required this.label,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'token': token,
      'label': label,
      'created_at': createdAt,
    };
  }

  factory UsbKey.fromMap(Map<String, dynamic> map) {
    return UsbKey(
      id: map['id'] as int?,
      token: map['token'] as String,
      label: map['label'] as String,
      createdAt: map['created_at'] as String,
    );
  }
}
