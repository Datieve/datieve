class LocalTab {
  final String id;
  final String label;
  final String path;

  const LocalTab({
    required this.id,
    required this.label,
    required this.path,
  });

  LocalTab copyWith({String? label, String? path}) {
    return LocalTab(
      id: id,
      label: label ?? this.label,
      path: path ?? this.path,
    );
  }
}