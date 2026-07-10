import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/app_shell.dart';
import 'theme/langbai_theme.dart';

const _defaultThemeName = String.fromEnvironment(
  'DEFAULT_THEME_MODE',
  defaultValue: 'system',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LangbaiResolverApp());
}

class LangbaiResolverApp extends StatefulWidget {
  const LangbaiResolverApp({super.key});

  @override
  State<LangbaiResolverApp> createState() => _LangbaiResolverAppState();
}

class _LangbaiResolverAppState extends State<LangbaiResolverApp> {
  ThemeMode _themeMode = switch (_defaultThemeName) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  @override
  void initState() {
    super.initState();
    _restoreTheme();
  }

  Future<void> _restoreTheme() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString('theme_mode');
    if (!mounted || saved == null) return;
    setState(() {
      _themeMode = switch (saved) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    });
  }

  Future<void> _setThemeMode(ThemeMode value) async {
    setState(() => _themeMode = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('theme_mode', value.name);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'langbai解析',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: LangbaiTheme.light(),
      darkTheme: LangbaiTheme.dark(),
      home: AppShell(
        themeMode: _themeMode,
        onThemeModeChanged: _setThemeMode,
      ),
    );
  }
}
