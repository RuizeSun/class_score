import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass_buttons.dart';

/// 下拉菜单浮层的玻璃参数：比按钮略厚、略亮，保证选项可读。
const LiquidGlassSettings _menuGlassSettings = LiquidGlassSettings(
  glassColor: Color(0x47FFFFFF),
  thickness: 24,
  blur: 16,
  frost: 8,
  frostOpacity: 0.4,
  chromaticAberration: 0.06,
  rimShade: 0.55,
  rimLight: 1.2,
  glowIntensity: 0.8,
  shadowElevation: 0.8,
);

/// 下拉输入框的玻璃参数：与 GlassSegmentedControl 的轨道同色，
/// 避免工具条里一个白一个灰。
const LiquidGlassSettings _fieldGlassSettings = LiquidGlassSettings(
  glassColor: Color(0x21767680),
  thickness: 18,
  blur: 10,
  frost: 6,
  frostOpacity: 0.3,
  chromaticAberration: 0.05,
  rimShade: 0.45,
  rimLight: 0.6,
  glowIntensity: 0.5,
  shadowElevation: 0,
  shadow: [],
);

/// 液态玻璃复选框（对应 `Checkbox`）。
class GlassCheckbox extends StatelessWidget {
  const GlassCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = 24,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    return Semantics(
      checked: value,
      enabled: enabled,
      label: semanticLabel,
      child: GlassIconButton(
        icon: value ? const Icon(Icons.check) : const SizedBox.shrink(),
        onPressed: enabled ? () => onChanged!(!value) : null,
        size: size,
        iconSize: size * 0.62,
        iconColor: value ? scheme.onPrimary : Colors.transparent,
        shape: GlassIconButtonShape.roundedSquare,
        borderRadius: size * 0.3,
        style: value ? GlassButtonStyle.prominent : GlassButtonStyle.filled,
        tintColor: value ? scheme.primary.withValues(alpha: 0.72) : null,
        settings: glassButtonSettings,
        glowRadius: 8,
      ),
    );
  }
}

/// 液态玻璃单选框（对应 `Radio`）。
class GlassRadio extends StatelessWidget {
  const GlassRadio({
    super.key,
    required this.selected,
    required this.onTap,
    this.size = 24,
    this.semanticLabel,
  });

  final bool selected;
  final VoidCallback? onTap;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      checked: selected,
      inMutuallyExclusiveGroup: true,
      enabled: onTap != null,
      label: semanticLabel,
      child: GlassIconButton(
        icon: selected
            ? Icon(Icons.circle, size: size * 0.36)
            : const SizedBox.shrink(),
        onPressed: onTap,
        size: size,
        shape: GlassIconButtonShape.circle,
        iconColor: selected ? scheme.onPrimary : Colors.transparent,
        style: selected ? GlassButtonStyle.prominent : GlassButtonStyle.filled,
        tintColor: selected ? scheme.primary.withValues(alpha: 0.72) : null,
        settings: glassButtonSettings,
        glowRadius: 8,
      ),
    );
  }
}

/// 用玻璃开关替代 `SwitchListTile`。
class GlassSwitchTile extends StatelessWidget {
  const GlassSwitchTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.secondary,
    this.contentPadding,
    this.dense = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final Widget? secondary;
  final EdgeInsetsGeometry? contentPadding;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return ListTile(
      dense: dense,
      contentPadding: contentPadding,
      leading: secondary,
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      onTap: enabled ? () => onChanged!(!value) : null,
      trailing: GlassSwitch(
        value: value,
        onChanged: onChanged,
        activeColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.55),
        inactiveColor: Colors.black.withValues(alpha: 0.10),
      ),
    );
  }
}

/// 用玻璃复选框替代 `CheckboxListTile`。
class GlassCheckboxTile extends StatelessWidget {
  const GlassCheckboxTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.contentPadding,
    this.dense = false,
    this.checkedSemanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final bool dense;
  final String? checkedSemanticLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return ListTile(
      dense: dense,
      contentPadding: contentPadding,
      leading: GlassCheckbox(
        value: value,
        onChanged: onChanged,
        semanticLabel: checkedSemanticLabel,
      ),
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      onTap: enabled ? () => onChanged!(!value) : null,
    );
  }
}

/// 用玻璃单选框替代 `RadioListTile`。
class GlassRadioTile extends StatelessWidget {
  const GlassRadioTile({
    super.key,
    required this.selected,
    required this.onTap,
    required this.title,
    this.subtitle,
    this.contentPadding,
    this.dense = false,
    this.semanticLabel,
  });

  final bool selected;
  final VoidCallback? onTap;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final bool dense;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return ListTile(
      dense: dense,
      contentPadding: contentPadding,
      leading: GlassRadio(
        selected: selected,
        onTap: onTap,
        semanticLabel: semanticLabel,
      ),
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      onTap: onTap,
    );
  }
}

/// 液态玻璃 Chip（对应 `ChoiceChip` / `FilterChip` / `InputChip`）。
class GlassChipControl extends StatelessWidget {
  const GlassChipControl({
    super.key,
    required this.label,
    this.child,
    this.icon,
    this.selected = false,
    this.onTap,
    this.onDeleted,
    this.enabled,
    this.tooltip,
    this.fontSize = 13,
    this.height = 32,
    this.foregroundColor,
  });

  final String label;
  final Widget? child;
  final Widget? icon;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDeleted;
  final bool? enabled;
  final String? tooltip;
  final double fontSize;
  final double height;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasHandler = onTap != null || onDeleted != null;
    final isEnabled = enabled ?? hasHandler;
    final foreground =
        foregroundColor ?? (selected ? scheme.primary : Colors.black87);

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          IconTheme(
            data: IconThemeData(color: foreground, size: 15),
            child: icon!,
          ),
          const SizedBox(width: 5),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child:
              child ??
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (onDeleted != null) ...[
          const SizedBox(width: 6),
          Semantics(
            button: true,
            label: '删除',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: isEnabled ? onDeleted : null,
              child: Icon(Icons.close, size: 15, color: foreground),
            ),
          ),
        ],
      ],
    );

    final chip = GlassActionButton(
      onPressed: isEnabled ? (onTap ?? () {}) : null,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      foregroundColor: foreground,
      tintColor: selected ? scheme.primary.withValues(alpha: 0.22) : null,
      fontSize: fontSize,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      shape: const LiquidOval(),
      child: content,
    );

    final message = tooltip;
    return message == null ? chip : Tooltip(message: message, child: chip);
  }
}

/// 分段控件中的一个选项。
class GlassSegmentedOption<T> {
  const GlassSegmentedOption({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

/// 液态玻璃分段控件（对应 `SegmentedButton`）。
///
/// 用官方 [GlassSegmentedControl]：浅色轨道 + 白色液态玻璃指示块，
/// 文本与图标沿用 Cupertino label 的对比度。
class GlassSegmentedChoice<T> extends StatelessWidget {
  const GlassSegmentedChoice({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.expand = false,
    this.width,
    this.height = 40,
  });

  final List<GlassSegmentedOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// 是否占满父级宽度（父级必须给出确定宽度）。
  final bool expand;

  /// 显式宽度；为空时按选项数量估算。
  final double? width;

  final double height;

  double get _defaultWidth =>
      options.length *
      (options.any((option) => option.icon != null) ? 96.0 : 84.0);

  @override
  Widget build(BuildContext context) {
    final selectedIndex = options.indexWhere(
      (option) => option.value == selected,
    );
    return SizedBox(
      width: width ?? (expand ? double.infinity : _defaultWidth),
      height: height,
      child: GlassSegmentedControl(
        segments: [
          for (final option in options)
            GlassSegment(
              label: option.label,
              icon: option.icon == null ? null : Icon(option.icon, size: 16),
            ),
        ],
        selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
        onSegmentSelected: (index) => onChanged(options[index].value),
        height: height,
        useOwnLayer: true,
      ),
    );
  }
}

/// 液态玻璃下拉选择框（对应 `DropdownButtonFormField`）。
///
/// 关闭态是玻璃按钮；展开后是真正的玻璃菜单（`MenuAnchor` + `GlassContainer`，
/// 背景会被液态玻璃模糊）。选项仍沿用原来的 [DropdownMenuItem.child] 组件。
class GlassDropdownField<T> extends StatefulWidget {
  const GlassDropdownField({
    super.key,
    required this.initialValue,
    required this.items,
    required this.onChanged,
    this.decoration,
    this.isExpanded = true,
    this.menuMaxHeight = 320,
    this.menuWidth = 240,
    this.height,
    this.menuRadius = 16,
  });

  final T? initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration? decoration;
  final bool isExpanded;
  final double menuMaxHeight;
  final double menuWidth;
  final double? height;
  final double menuRadius;

  @override
  State<GlassDropdownField<T>> createState() => _GlassDropdownFieldState<T>();
}

class _GlassDropdownFieldState<T> extends State<GlassDropdownField<T>> {
  late T? _value;
  MenuController? _controller;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  @override
  void didUpdateWidget(covariant GlassDropdownField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      _value = widget.initialValue;
    }
  }

  DropdownMenuItem<T>? get _selectedItem {
    for (final item in widget.items) {
      if (item.value == _value) return item;
    }
    return null;
  }

  bool get _enabled => widget.onChanged != null;

  void _select(DropdownMenuItem<T> item) {
    _controller?.close();
    setState(() => _value = item.value);
    widget.onChanged?.call(item.value);
  }

  @override
  Widget build(BuildContext context) {
    final labelText = widget.decoration?.labelText;
    final field = MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
          ),
        ),
      ),
      menuChildren: [_buildMenu(context)],
      builder: (context, controller, _) {
        _controller = controller;
        return _buildTrigger(context, controller);
      },
    );

    if (labelText == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          labelText,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.black54,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        field,
      ],
    );
  }

  Widget _buildTrigger(BuildContext context, MenuController controller) {
    final decoration = widget.decoration;
    final selected = _selectedItem;
    final hintText = decoration?.hintText ?? '';
    final prefixIcon = decoration?.prefixIcon;
    final fieldHeight =
        widget.height ?? (decoration?.isDense == true ? 40 : 44);

    return GlassButton.custom(
      onTap: _enabled
          ? () => controller.isOpen ? controller.close() : controller.open()
          : () {},
      enabled: _enabled,
      width: widget.isExpanded ? double.infinity : null,
      height: fieldHeight,
      shape: LiquidRoundedSuperellipse(borderRadius: fieldHeight / 2),
      settings: _fieldGlassSettings,
      glowColor: Colors.black.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            if (prefixIcon != null) ...[
              IconTheme(
                data: const IconThemeData(size: 18, color: Colors.black54),
                child: prefixIcon,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: selected != null
                  ? selected.child
                  : Text(
                      hintText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.black54,
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.expand_more, size: 20, color: Colors.black54),
          ],
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    final selected = _selectedItem;
    return SizedBox(
      width: widget.menuWidth,
      child: GlassContainer(
        padding: const EdgeInsets.all(6),
        shape: LiquidRoundedSuperellipse(borderRadius: widget.menuRadius),
        useOwnLayer: true,
        settings: _menuGlassSettings,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: widget.menuMaxHeight),
          child: Material(
            type: MaterialType.transparency,
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in widget.items)
                    _buildMenuItem(
                      context,
                      item,
                      item.value == selected?.value,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuItem(
    BuildContext context,
    DropdownMenuItem<T> item,
    bool selected,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: item.enabled ? () => _select(item) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            Expanded(
              child: Opacity(
                opacity: item.enabled ? 1 : 0.5,
                child: item.child,
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.check,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
