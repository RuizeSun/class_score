import 'package:flutter/material.dart';

/// 学生显示的统一规范：`姓名#学号`，其中学号使用灰色字体。
///
/// 全应用只保留这一处实现，避免各页面各写一套（历史上出现过
/// `姓名 (学号)`、`姓名  学号`、`学号: xxx` 三种写法）。
class StudentDisplay {
  StudentDisplay._();

  /// 姓名与学号之间的分隔符。
  static const String separator = '#';

  /// 学号默认颜色（灰色）。
  static Color get numberColor => Colors.grey.shade600;

  /// 学号相对姓名颜色的不透明度。
  ///
  /// 姓名带色时（如评分卡片选中态的绿色），学号跟随同一色相并降低不透明度，
  /// 既保持一致的视觉语言，又保留「姓名为主、学号为辅」的层级。
  static const double numberAlpha = 0.7;

  /// 视为「无彩色」的姓名颜色：学号不跟随，固定使用灰色。
  static const List<Color> _neutralNameColors = [
    Colors.black,
    Colors.black87,
    Colors.black54,
    Colors.black45,
    Colors.white,
    Colors.white70,
  ];

  /// 根据姓名颜色推导学号颜色。
  ///
  /// 姓名无色（或本身是中性色 / 灰色）时返回 [numberColor]；
  /// 姓名带色时返回同色、[numberAlpha] 不透明度。
  static Color numberColorFor(Color? nameColor) {
    if (nameColor == null ||
        nameColor == numberColor ||
        _neutralNameColors.contains(nameColor)) {
      return numberColor;
    }
    return nameColor.withValues(alpha: numberAlpha);
  }

  /// 纯文本形式：无富文本能力的场景（如 SnackBar 文案）使用。
  static String plainText(String name, String studentNumber) =>
      studentNumber.isEmpty ? name : '$name$separator$studentNumber';

  /// 富文本形式：`Text.rich` 与 `TextPainter`（宽度测量）共用同一实现，
  /// 保证测量宽度与实际渲染一致。
  ///
  /// [studentNumber] 为空时只返回姓名，不出现分隔符。
  static InlineSpan span({
    required String name,
    String? studentNumber,
    TextStyle? nameStyle,
    Color? numberColor,
  }) {
    final number = studentNumber ?? '';
    if (number.isEmpty) {
      return TextSpan(text: name, style: nameStyle);
    }
    final style = nameStyle ?? const TextStyle();
    return TextSpan(
      children: [
        TextSpan(text: name, style: nameStyle),
        TextSpan(
          text: '$separator$number',
          style: style.copyWith(
            color: numberColor ?? StudentDisplay.numberColorFor(style.color),
          ),
        ),
      ],
    );
  }
}

/// `姓名#学号` 的通用展示组件，学号使用灰色字体。
///
/// 学号为空时只显示姓名，不出现分隔符。
class StudentNameText extends StatelessWidget {
  const StudentNameText({
    super.key,
    required this.name,
    required this.studentNumber,
    this.style,
    this.numberColor,
    this.maxLines,
    this.overflow,
  });

  /// 学生姓名。
  final String name;

  /// 学号；为空时只显示姓名。
  final String studentNumber;

  /// 姓名样式（学号样式在其基础上应用学号颜色）。
  final TextStyle? style;

  /// 学号颜色；不传时按 [StudentDisplay.numberColorFor] 推导（默认灰色）。
  final Color? numberColor;

  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      StudentDisplay.span(
        name: name,
        studentNumber: studentNumber,
        nameStyle: style,
        numberColor: numberColor,
      ),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
