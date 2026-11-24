import 'package:flutter/material.dart';

/// 全应用配色：冷灰底、白色大圆角卡片、靛蓝主色，与同系列的视频工具保持一致。
abstract final class AppColors {
  static const ink = Color(0xFF0F172A);
  static const body = Color(0xFF334155);
  static const muted = Color(0xFF64748B);
  static const faint = Color(0xFF94A3B8);
  static const paper = Color(0xFFF4F5FA);
  static const sunken = Color(0xFFF1F3F9);
  static const line = Color(0xFFE3E7F0);
  static const accent = Color(0xFF4F46E5);
  static const accentSoft = Color(0xFFEEF0FF);
  static const violet = Color(0xFF8B5CF6);
  static const night = Color(0xFF16143E);
  static const nightAlt = Color(0xFF3730A3);
  static const glow = Color(0xFFC7D2FE);
  static const success = Color(0xFF059669);
  static const warning = Color(0xFFD97706);
  static const danger = Color(0xFFDC2626);
  static const sky = Color(0xFF0EA5E9);
  static const amber = Color(0xFFF59E0B);

  /// 主按钮与强调色块的渐变。
  static const accentGradient = LinearGradient(
    colors: [accent, violet],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  /// 深色头图的渐变。
  static const nightGradient = LinearGradient(
    colors: [night, nightAlt],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// 卡片与浮层的柔和阴影。
  static const softShadow = [
    BoxShadow(color: Color(0x1A1E295A), blurRadius: 18, offset: Offset(0, 6)),
  ];
}

/// 圆角色块里的图标；[solid] 为实色渐变底、白色图标。
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.color = AppColors.accent,
    this.size = 40,
    this.solid = false,
  });

  final IconData icon;
  final Color color;
  final double size;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: solid ? null : color.withValues(alpha: 0.11),
        gradient: solid
            ? LinearGradient(
                colors: [color, Color.lerp(color, Colors.black, 0.25)!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(icon, size: size * 0.5, color: solid ? Colors.white : color),
    );
  }
}

/// 渐变底的主按钮，内部仍是 [FilledButton]，保留按钮语义与禁用状态。
class GradientFilledButton extends StatelessWidget {
  const GradientFilledButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.height = 50,
  });

  final VoidCallback? onPressed;
  final Widget label;
  final Widget? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final style = FilledButton.styleFrom(
      minimumSize: Size.fromHeight(height),
      backgroundColor: Colors.transparent,
      disabledBackgroundColor: Colors.transparent,
      shadowColor: Colors.transparent,
      foregroundColor: Colors.white,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: enabled ? AppColors.accentGradient : null,
        color: enabled ? null : AppColors.sunken,
        borderRadius: BorderRadius.circular(16),
        boxShadow: enabled
            ? const [
                BoxShadow(
                  color: Color(0x334F46E5),
                  blurRadius: 14,
                  offset: Offset(0, 5),
                ),
              ]
            : null,
      ),
      child: icon == null
          ? FilledButton(onPressed: onPressed, style: style, child: label)
          : FilledButton.icon(
              onPressed: onPressed,
              style: style,
              icon: icon!,
              label: label,
            ),
    );
  }
}
