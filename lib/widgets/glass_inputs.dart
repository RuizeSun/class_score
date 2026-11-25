import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass_buttons.dart';

/// 液态玻璃输入框的玻璃参数。
///
/// 直接复用成排控件的「轻玻璃」档（见 [denseGlassButtonSettings]）：颜色、
/// 厚度、frost、边缘高光与按钮完全一致，输入框因此和旁边的下拉框、分段控件
/// 是同一档玻璃，不会出现「一个白一个灰」。
///
/// 只把 blur 归零：输入框几乎都落在纯色页面/卡片上，背景模糊看不出差别，
/// 但 blur > 0 会为每个输入框推开一层全窗口 BackdropFilterLayer——课表表格
/// 一屏就有十几个输入框，正是低配机掉帧的来源。**不要连 frost 一起归零**，
/// 那会让玻璃面退化成「描边 + 纯色底」两层，重绘/动画时会错位。
const LiquidGlassSettings glassInputSettings = denseGlassButtonSettings;

/// 液态玻璃输入框（对应 Material 的 TextField）。
///
/// 底层是 liquid_glass_widgets 的 [GlassTextField]（内部 CupertinoTextField +
/// AdaptiveGlass），因此保留原生文本编辑、选区、输入法与焦点行为；这里只补齐
/// 项目里 Material 输入框一直在用的那套约定：
///
/// - 标签画在输入框上方左上角（[label]），错误/提示文字画在下方；
/// - [dense] 对应原来的 isDense: true，高度压到 36，用于表格、行内输入；
/// - 默认不做按压缩放：输入框是常驻编辑控件，一按下就整体放大既不好看，
///   也会让所在表格行跟着重排；
/// - 形状直接用胶囊（LiquidRoundedSuperellipse，半径 = 高度/2），与按钮、
///   下拉框保持一致。
class GlassInput extends StatefulWidget {
  const GlassInput({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.initialValue,
    this.obscureText = false,
    this.enabled = true,
    this.autofocus = false,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.prefixIcon,
    this.suffixIcon,
    this.onSuffixTap,
    this.errorText,
    this.helperText,
    this.dense = false,
    this.height,
    this.interactionBehavior = GlassInteractionBehavior.none,
  });

  final TextEditingController? controller;

  /// 输入框上方的标签；为空时不占位置。
  final String? label;

  /// 空值时的占位文字。
  final String? hint;

  /// 初始文本：仅在没传 [controller] 时用于建内部控制器。
  final String? initialValue;

  final bool obscureText;
  final bool enabled;
  final bool autofocus;
  final int maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final VoidCallback? onSuffixTap;

  /// 校验失败时的红色提示（优先于 [helperText]）。
  final String? errorText;

  /// 辅助说明文字。
  final String? helperText;

  /// 行内 / 表格里用的紧凑高度（36）。
  final bool dense;

  /// 显式高度；为空时按 [dense] 取 36 / 44。
  final double? height;

  /// 按压交互：输入框默认全关（见类注释）。
  final GlassInteractionBehavior interactionBehavior;

  @override
  State<GlassInput> createState() => _GlassInputState();
}

class _GlassInputState extends State<GlassInput> {
  TextEditingController? _internalController;

  TextEditingController? get _effectiveController =>
      widget.controller ?? _internalController;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _internalController = TextEditingController(text: widget.initialValue);
    }
  }

  @override
  void didUpdateWidget(covariant GlassInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == null && widget.controller != null) {
      _internalController?.dispose();
      _internalController = null;
    } else if (oldWidget.controller != null && widget.controller == null) {
      _internalController = TextEditingController(text: widget.initialValue);
    } else if (widget.controller == null &&
        oldWidget.initialValue != widget.initialValue &&
        _internalController != null &&
        _internalController!.text != (widget.initialValue ?? '')) {
      // 仍用内部控制器：initialValue 变化时同步过去（例如编辑对象切换）。
      _internalController!.text = widget.initialValue ?? '';
    }
  }

  @override
  void dispose() {
    _internalController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fieldHeight = widget.height ?? (widget.dense ? 36 : 44);
    final radius = fieldHeight / 2;
    final fontSize = widget.dense ? 13.0 : 14.0;

    final field = GlassTextField(
      controller: _effectiveController,
      placeholder: widget.hint,
      prefixIcon: widget.prefixIcon,
      suffixIcon: widget.suffixIcon,
      onSuffixTap: widget.onSuffixTap,
      obscureText: widget.obscureText,
      enabled: widget.enabled,
      readOnly: !widget.enabled,
      autofocus: widget.autofocus,
      maxLines: widget.maxLines,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      inputFormatters: widget.inputFormatters,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      height: fieldHeight,
      padding: EdgeInsets.symmetric(horizontal: widget.dense ? 12 : 14),
      iconSpacing: 8,
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      settings: glassInputSettings,
      useOwnLayer: true,
      interactionBehavior: widget.interactionBehavior,
      textStyle: TextStyle(
        fontSize: fontSize,
        height: 1.2,
        color: Colors.black87,
      ),
      placeholderStyle: TextStyle(
        fontSize: fontSize,
        color: Colors.black45,
      ),
    );

    final hasLabel = widget.label != null && widget.label!.isNotEmpty;
    final message = widget.errorText ?? widget.helperText;

    if (!hasLabel && message == null) return field;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasLabel) ...[
          Text(
            widget.label!,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.black54,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
        ],
        field,
        if (message != null) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: widget.errorText != null
                    ? Colors.red.shade700
                    : Colors.black45,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 多行液态玻璃输入框（对应 TextField(maxLines: n)）。
///
/// 与 [GlassInput] 的差别：高度随内容增长（minLines..maxLines），圆角收小到
/// 12（多行框做成胶囊会让四角显得很挤），其余玻璃参数完全一致。
class GlassTextAreaInput extends StatelessWidget {
  const GlassTextAreaInput({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.minLines = 3,
    this.maxLines = 5,
    this.enabled = true,
    this.autofocus = false,
    this.onChanged,
    this.errorText,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final int minLines;
  final int maxLines;
  final bool enabled;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null && label!.isNotEmpty) ...[
          Text(
            label!,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.black54,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
        ],
        GlassTextField(
          controller: controller,
          placeholder: hint,
          minLines: minLines,
          maxLines: maxLines,
          enabled: enabled,
          autofocus: autofocus,
          onChanged: onChanged,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: const LiquidRoundedSuperellipse(borderRadius: 12),
          settings: glassInputSettings,
          useOwnLayer: true,
          interactionBehavior: GlassInteractionBehavior.none,
          textStyle: const TextStyle(
            fontSize: 14,
            height: 1.35,
            color: Colors.black87,
          ),
          placeholderStyle: const TextStyle(
            fontSize: 14,
            color: Colors.black45,
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              errorText!,
              style: TextStyle(fontSize: 12, color: Colors.red.shade700),
            ),
          ),
        ],
      ],
    );
  }
}
