import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// 统一的窗口尺寸配置。
///
/// 目标尺寸为 1280x720（课堂一体机 / 投影常用分辨率）。
/// 若显示器工作区更小（例如任务栏占位后只有 1280x680），
/// 会自动收缩到工作区大小，保证窗口完整可见、不被裁切。
class WindowService {
  WindowService._();

  /// 期望的窗口尺寸
  static const Size preferredSize = Size(1280, 720);

  static Size _size = preferredSize;

  /// 实际生效的窗口尺寸
  static Size get size => _size;

  /// 初始化窗口管理器并按屏幕工作区计算最终尺寸
  static Future<void> setup() async {
    await windowManager.ensureInitialized();
    _size = await _resolveSize();

    final options = WindowOptions(
      size: _size,
      minimumSize: _size,
      maximumSize: _size,
      center: true,
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  /// 固定窗口尺寸（禁用最大化 / 手动调整）
  static Future<void> applyFixedSize() async {
    await windowManager.setMaximumSize(_size);
    await windowManager.setMinimumSize(_size);
  }

  static Future<Size> _resolveSize() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final work = display.visibleSize ?? display.size;

      final width = preferredSize.width <= work.width
          ? preferredSize.width
          : work.width;
      final height = preferredSize.height <= work.height
          ? preferredSize.height
          : work.height;

      return Size(width, height);
    } catch (_) {
      // 获取屏幕信息失败时使用期望尺寸
      return preferredSize;
    }
  }
}
