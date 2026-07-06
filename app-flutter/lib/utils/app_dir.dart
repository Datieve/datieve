import 'dart:io';

class AppDir {
  static String? _basePath;

  static Future<void> initialize() async {
    if (_basePath != null) return;
    _basePath = _computePath();
    await Directory(_basePath!).create(recursive: true);
  }

  static String _computePath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (Platform.isWindows) {
      return '$home\\.datieve-app';
    }
    return '$home/.datieve-app';
  }

  static String get basePath => _basePath ??= _computePath();
}
