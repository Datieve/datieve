class FileTag {
  final String id;
  final String name;
  final String color;

  const FileTag({
    required this.id,
    required this.name,
    required this.color,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
      };

  factory FileTag.fromJson(Map<String, dynamic> json) => FileTag(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        color: json['color'] as String? ?? '#64748b',
      );
}

List<FileTag> defaultFileTags() => const [
      FileTag(id: 'home', name: 'Home', color: '#2563eb'),
      FileTag(id: 'work', name: 'Work', color: '#dc2626'),
      FileTag(id: 'photos', name: 'Photos', color: '#d97706'),
      FileTag(id: 'important', name: 'Important', color: '#16a34a'),
    ];