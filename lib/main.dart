import 'package:flutter/material.dart';

import 'ui/home_page.dart';

export 'core/app_update.dart';
export 'core/coord.dart';
export 'core/coordinate_input.dart';
export 'core/models.dart';
export 'core/search_api.dart';

void main() => runApp(const FakeLocationApp());

class FakeLocationApp extends StatelessWidget {
  const FakeLocationApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6C4BB6),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: '虚拟定位',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF6F4FB),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: InputBorder.none,
          isDense: true,
        ),
      ),
      home: const HomePage(),
    );
  }
}
