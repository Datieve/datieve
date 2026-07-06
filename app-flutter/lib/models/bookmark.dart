class Bookmark {
  final String id;
  final String label;
  final String path;

  const Bookmark({
    required this.id,
    required this.label,
    required this.path,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'path': path,
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
        path: json['path'] as String? ?? '',
      );
}