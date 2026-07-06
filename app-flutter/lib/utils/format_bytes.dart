String formatBytes(num bytes, {bool binary = true}) {
  if (bytes <= 0) return '0 B';
  const k = 1024;
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= k && unit < units.length - 1) {
    value /= k;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : value >= 10 ? 1 : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}