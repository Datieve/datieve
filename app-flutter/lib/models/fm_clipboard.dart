class FmClipboard {
  final String op;
  final List<String> paths;
  final String scope;

  const FmClipboard({
    required this.op,
    required this.paths,
    this.scope = 'local',
  });
}