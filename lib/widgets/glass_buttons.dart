import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 与解锁卡片、状态栏同源的磨砂光学参数。
const LiquidGlassSettings glassButtonSettings = LiquidGlassSettings(
  glassColor: Color(0x24FFFFFF),
  thickness: 18,
  blur: 10,
  frost: 6,
  frostOpacity: 0.32,
  chromaticAberration: 0.06,
  rimShade: 0.5,
  rimLight: 1.1,
  glowIntensity: 0.8,
);

/// 高密度控件（列表行 / 表格行 / 工具栏里的图标按钮、勾选框）用的「轻玻璃」。
///
/// 与 [glassButtonSettings] 的**颜色、厚度、边缘高光、投影全部一致**，只把
/// `blur`（背景模糊）归零——在本应用里这一项一个像素都不会变，代价却极大：
///
/// - 所有页面都是纯色 Material 底色，没有背景图。对一块纯色做高斯模糊，
///   结果还是同一块纯色，肉眼分辨不出。
/// - 但只要 `blur > 0`，每个玻璃面都会推开一层**全窗口的
///   `BackdropFilterLayer`**（见 liquid_glass_widgets 的
///   `LightweightLiquidGlass.paint`：`blurSigma > 0` 才 pushLayer）。
///   合成器要为每个这样的控件把整块 1280×800 的画面拷贝一遍。
/// - 一条评分记录带 3 颗图标按钮、一屏十几条、课表表格每行两个下拉框……
///   一帧几十次全窗口拷贝，正是低配一体机（核显 + i3）掉到 30fps 以下的主因。
///   blur 归零后这些控件不再产生任何合成层，着色器照常画圆角、厚度与高光。
///
/// 需要真正「透出底下内容」的大面积玻璃（状态栏胶囊、底部导航条、下拉菜单
/// 浮层、解锁卡片）仍用 [glassButtonSettings]。
const LiquidGlassSettings denseGlassButtonSettings = LiquidGlassSettings(
  glassColor: Color(0x24FFFFFF),
  thickness: 18,
  blur: 0,
  frost: 0,
  frostOpacity: 0.32,
  chromaticAberration: 0.06,
  rimShade: 0.5,
  rimLight: 1.1,
  glowIntensity: 0.8,
);

/// 液态玻璃动作按钮的两种外观档位。
enum GlassActionVariant {
  /// 中性磨砂玻璃：用于次要操作（原 TextButton / OutlinedButton）。
  filled,

  /// 强调玻璃：用于主要操作（原 ElevatedButton / FilledButton）。
  prominent,

  /// 无静止背景，仅保留按压光效：用于分段控件未选中项等。
  transparent,
}

/// 液态玻璃文字 / 图文按钮。
///
/// 作为 Material 按钮的替身，保留 [onPressed] 为 null 即禁用的语义。
class GlassActionButton extends StatelessWidget {
  const GlassActionButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.variant = GlassActionVariant.filled,
    this.height = 40,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.foregroundColor,
    this.tintColor,
    this.fontSize = 14,
    this.fontWeight,
    this.tooltip,
    this.shape,
    this.dense = true,
  });

  /// 带图标的按钮（对应 `TextButton.icon` / `FilledButton.icon` 等）。
  factory GlassActionButton.icon({
    Key? key,
    required VoidCallback? onPressed,
    required Widget icon,
    required Widget label,
    GlassActionVariant variant = GlassActionVariant.filled,
    double height = 40,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 16),
    Color? foregroundColor,
    Color? tintColor,
    double fontSize = 14,
    FontWeight? fontWeight,
    String? tooltip,
    LiquidShape? shape,
    bool dense = true,
  }) {
    return GlassActionButton(
      key: key,
      onPressed: onPressed,
      variant: variant,
      height: height,
      padding: padding,
      foregroundColor: foregroundColor,
      tintColor: tintColor,
      fontSize: fontSize,
      fontWeight: fontWeight,
      tooltip: tooltip,
      shape: shape,
      dense: dense,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [icon, const SizedBox(width: 8), label],
      ),
    );
  }

  final VoidCallback? onPressed;
  final Widget child;
  final GlassActionVariant variant;
  final double height;
  final EdgeInsetsGeometry padding;
  final Color? foregroundColor;
  final Color? tintColor;
  final double fontSize;
  final FontWeight? fontWeight;
  final String? tooltip;
  final LiquidShape? shape;

  /// 是否使用「轻玻璃」档（见 [denseGlassButtonSettings]）。
  ///
  /// 默认开启：按钮几乎都落在纯色页面 / 卡片上，背景模糊在这里画不出任何
  /// 可见差异，却要为每个按钮付一次整窗画面拷贝。少数压在真实内容（图片、
  /// 另一层玻璃、可滚动正文）之上的按钮可传 false 换回完整磨砂。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isProminent = variant == GlassActionVariant.prominent;
    final foreground =
        foregroundColor ?? (isProminent ? scheme.onPrimary : Colors.black87);
    final tint = variant == GlassActionVariant.transparent
        ? null
        : tintColor ??
              (isProminent ? scheme.primary.withValues(alpha: 0.62) : null);
    final buttonStyle = switch (variant) {
      GlassActionVariant.prominent => GlassButtonStyle.prominent,
      GlassActionVariant.filled => GlassButtonStyle.filled,
      GlassActionVariant.transparent => GlassButtonStyle.transparent,
    };

    final button = GlassButton.custom(
      onTap: onPressed ?? () {},
      enabled: onPressed != null,
      height: height,
      shape: shape ?? LiquidRoundedSuperellipse(borderRadius: height / 2),
      style: buttonStyle,
      settings: dense ? denseGlassButtonSettings : glassButtonSettings,
      tintColor: tint,
      glowColor: foreground.withValues(alpha: 0.16),
      child: Padding(
        padding: padding,
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: fontWeight ?? FontWeight.w600,
            color: foreground,
          ),
          child: IconTheme.merge(
            data: IconThemeData(color: foreground, size: fontSize + 3),
            child: child,
          ),
        ),
      ),
    );

    final text = tooltip;
    return text == null ? button : Tooltip(message: text, child: button);
  }
}

/// 液态玻璃图标按钮（对应 `IconButton` / `IconButton.filled`）。
class GlassIconAction extends StatelessWidget {
  const GlassIconAction({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 40,
    this.iconSize,
    this.foregroundColor,
    this.tintColor,
    this.variant = GlassActionVariant.filled,
    this.dense = true,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double? iconSize;
  final Color? foregroundColor;
  final Color? tintColor;
  final GlassActionVariant variant;

  /// 是否使用「轻玻璃」档（见 [denseGlassButtonSettings]）。
  ///
  /// 图标按钮几乎都成排落在列表行 / 工具栏里，是背景模糊最贵、收益最低的
  /// 一类控件，因此默认开启；压在真实内容之上时传 false。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isProminent = variant == GlassActionVariant.prominent;
    final foreground =
        foregroundColor ?? (isProminent ? scheme.onPrimary : Colors.black87);
    final tint = variant == GlassActionVariant.transparent
        ? null
        : tintColor ??
              (isProminent ? scheme.primary.withValues(alpha: 0.62) : null);

    final button = GlassIconButton(
      icon: icon,
      onPressed: onPressed,
      size: size,
      iconSize: iconSize ?? size * 0.5,
      iconColor: foreground,
      shape: GlassIconButtonShape.circle,
      settings: dense ? denseGlassButtonSettings : glassButtonSettings,
      tintColor: tint,
      style: isProminent ? GlassButtonStyle.prominent : GlassButtonStyle.filled,
      glowColor: foreground.withValues(alpha: 0.16),
      glowRadius: 14,
      semanticLabel: tooltip,
    );

    final text = tooltip;
    return text == null ? button : Tooltip(message: text, child: button);
  }
}

/// 给非玻璃的点击控件（如 `PopupMenuButton`）套一层玻璃外壳。
///
/// 外壳只负责背景，不参与命中测试，点击仍由内部控件处理。
class GlassIconFrame extends StatelessWidget {
  const GlassIconFrame({
    super.key,
    required this.child,
    this.size = 40,
    this.dense = true,
  });

  final Widget child;
  final double size;

  /// 是否使用「轻玻璃」档（见 [denseGlassButtonSettings]）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return AdaptiveGlass(
      shape: const LiquidOval(),
      settings: dense ? denseGlassButtonSettings : glassButtonSettings,
      quality:
          GlassThemeData.of(context).qualityFor(context) ??
          GlassQuality.standard,
      child: SizedBox(width: size, height: size, child: child),
    );
  }
}
