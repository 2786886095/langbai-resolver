import 'package:flutter/material.dart';

@immutable
class LangbaiPalette extends ThemeExtension<LangbaiPalette> {
  const LangbaiPalette({
    required this.canvas,
    required this.surfaceRaised,
    required this.border,
    required this.textMuted,
    required this.success,
    required this.warning,
    required this.navigationSelected,
  });

  final Color canvas;
  final Color surfaceRaised;
  final Color border;
  final Color textMuted;
  final Color success;
  final Color warning;
  final Color navigationSelected;

  @override
  LangbaiPalette copyWith({
    Color? canvas,
    Color? surfaceRaised,
    Color? border,
    Color? textMuted,
    Color? success,
    Color? warning,
    Color? navigationSelected,
  }) {
    return LangbaiPalette(
      canvas: canvas ?? this.canvas,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      border: border ?? this.border,
      textMuted: textMuted ?? this.textMuted,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      navigationSelected: navigationSelected ?? this.navigationSelected,
    );
  }

  @override
  LangbaiPalette lerp(ThemeExtension<LangbaiPalette>? other, double t) {
    if (other is! LangbaiPalette) return this;
    return LangbaiPalette(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      border: Color.lerp(border, other.border, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      navigationSelected:
          Color.lerp(navigationSelected, other.navigationSelected, t)!,
    );
  }
}

class LangbaiTheme {
  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        primary: const Color(0xFF6076FF),
        background: const Color(0xFF070D19),
        surface: const Color(0xFF0E1728),
        palette: const LangbaiPalette(
          canvas: Color(0xFF070D19),
          surfaceRaised: Color(0xFF121E33),
          border: Color(0xFF263550),
          textMuted: Color(0xFF91A0BA),
          success: Color(0xFF5FD8AE),
          warning: Color(0xFFFFC46B),
          navigationSelected: Color(0xFF162A58),
        ),
      );

  static ThemeData light() => _build(
        brightness: Brightness.light,
        primary: const Color(0xFF3F5FF3),
        background: const Color(0xFFF7F8FC),
        surface: Colors.white,
        palette: const LangbaiPalette(
          canvas: Color(0xFFF7F8FC),
          surfaceRaised: Color(0xFFFFFFFF),
          border: Color(0xFFDCE3F1),
          textMuted: Color(0xFF66758E),
          success: Color(0xFF24B889),
          warning: Color(0xFFB86E16),
          navigationSelected: Color(0xFFE8EDFF),
        ),
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color primary,
    required Color background,
    required Color surface,
    required LangbaiPalette palette,
  }) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
      primary: primary,
      surface: surface,
      error: const Color(0xFFE45468),
    );
    final isDark = brightness == Brightness.dark;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'PingFang SC',
        'Noto Sans CJK SC',
        'Noto Sans SC',
        'sans-serif',
      ],
      extensions: [palette],
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: isDark ? const Color(0xFFF4F7FF) : const Color(0xFF172033),
        displayColor:
            isDark ? const Color(0xFFF4F7FF) : const Color(0xFF172033),
      ),
      dividerColor: palette.border,
      cardColor: surface,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceRaised,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: palette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          side: BorderSide(color: palette.border),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      iconTheme: IconThemeData(
        color: isDark ? const Color(0xFFBCC8DC) : const Color(0xFF50617A),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1B2940) : const Color(0xFF172033),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: palette.navigationSelected,
        height: 72,
      ),
    );
  }
}

class LangbaiCard extends StatelessWidget {
  const LangbaiCard({
    super.key,
    this.child,
    this.color,
    this.clipBehavior = Clip.none,
    this.margin = EdgeInsets.zero,
  });

  final Widget? child;
  final Color? color;
  final Clip clipBehavior;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color ?? Theme.of(context).colorScheme.surface,
      elevation: 0,
      margin: margin,
      clipBehavior: clipBehavior,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.palette.border),
      ),
      child: child,
    );
  }
}

extension LangbaiThemeContext on BuildContext {
  LangbaiPalette get palette => Theme.of(this).extension<LangbaiPalette>()!;
}
