import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'screens/file_manager_screen.dart';
import 'src/rust/frb_generated.dart';
import 'state/datieve_state.dart';
import 'theme/css_tokens.dart';
import 'theme/datieve_theme.dart';
import 'widgets/app_error_boundary.dart';
import 'widgets/ui/spinners.dart';
import 'utils/app_dir.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDir.initialize();
  await RustLib.init();
  runApp(const DatieveApp());
}

class DatieveApp extends StatefulWidget {
  const DatieveApp({super.key});

  @override
  State<DatieveApp> createState() => _DatieveAppState();
}

class _DatieveAppState extends State<DatieveApp> with WidgetsBindingObserver {
  final DatieveState state = DatieveState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.addListener(_onState);
    state.init();
  }

  void _onState() => setState(() {});

  @override
  void didChangePlatformBrightness() {
    if (state.settings.theme == 'system') setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.removeListener(_onState);
    super.dispose();
  }

  ThemeMode _themeMode() {
    switch (state.settings.theme) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }

  bool _effectiveDark(BuildContext context) {
    switch (state.settings.theme) {
      case 'dark':
        return true;
      case 'light':
        return false;
      default:
        return MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = _effectiveDark(context);
    final colors = dark ? DatieveColors.dark : DatieveColors.light;

    return MaterialApp(
      title: 'Datieve',
      debugShowCheckedModeBanner: false,
      theme: DatieveTheme.material(false),
      darkTheme: DatieveTheme.material(true),
      themeMode: _themeMode(),
      builder: (context, child) {
        return Theme(
          data: dark ? DatieveTheme.material(true) : DatieveTheme.material(false),
          child: DefaultTextStyle(
            style: GoogleFonts.inter(
              color: colors.ink,
              fontSize: 14,
            ),
            child: DecoratedBox(
              decoration: Tw(colors).appBackground(dark),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
      home: AppErrorBoundary(
        child: Material(
          type: MaterialType.transparency,
          child: state.loading
              ? Scaffold(
                  backgroundColor: Colors.transparent,
                  body: Center(
                    child: SlateSpinner(colors: colors),
                  ),
                )
              : _buildScreen(colors),
        ),
      ),
    );
  }

  Widget _buildScreen(DatieveColors colors) {
    if (state.globalError != null) {
      return _GlobalErrorBanner(
        message: state.globalError!,
        onDismiss: () {
          state.globalError = null;
          state.notifyListeners();
        },
        child: _screenForRoute(),
      );
    }
    return _screenForRoute();
  }

  Widget _screenForRoute() => FileManagerScreen(state: state);
}

class _GlobalErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;
  final Widget child;

  const _GlobalErrorBanner({
    required this.message,
    required this.onDismiss,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(Tw.radiusLg),
            color: const Color(0xFFDC2626),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'RUNTIME ERROR CAUGHT',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: onDismiss,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: const Color(0xFF991B1B),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        child: const Text('Dismiss', style: TextStyle(fontSize: 10)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 400),
                    child: SingleChildScrollView(
                      child: Text(
                        message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}