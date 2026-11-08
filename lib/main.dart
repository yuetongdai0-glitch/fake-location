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
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F7B6C),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF0F7B6C),
          onPrimary: Colors.white,
          surface: Colors.white,
        );
    return MaterialApp(
      title: '虚拟定位',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF2F4F3),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: InputBorder.none,
          isDense: true,
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
          space: 1,
          thickness: 1,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          showDragHandle: true,
          dragHandleColor: Color(0xFFD6DBD9),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        listTileTheme: const ListTileThemeData(
          iconColor: Color(0xFF5B6B67),
        ),
      ),
      home: const HomePage(),
    );
  }
}
