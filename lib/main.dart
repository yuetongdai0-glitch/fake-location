import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ui/home_page.dart';

export 'core/app_update.dart';
export 'core/coord.dart';
export 'core/coordinate_input.dart';
export 'core/models.dart';
export 'core/search_api.dart';
export 'core/user_message.dart';

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
      // 产品统一使用简体中文，系统为英文时也保持复制、粘贴和弹层提示为中文。
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
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
