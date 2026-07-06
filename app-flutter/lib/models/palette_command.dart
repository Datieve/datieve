typedef PaletteRun = void Function();

class PaletteCommand {
  final String label;
  final String detail;
  final String category;
  final PaletteRun run;
  final bool enabled;

  const PaletteCommand({
    required this.label,
    required this.detail,
    required this.category,
    required this.run,
    this.enabled = true,
  });
}