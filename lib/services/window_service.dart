import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// 统一的窗口尺寸配置。
///
/// [preferredClientSize] 指 Flutter 实际绘制的内容区（client area）尺寸，
/// 目标为 1280x800。
///
/// 注意：Windows 的窗口外框（含标题栏与边框）比内容区大，而
/// `window_manager.setSize` 设置的是"外框"。因此这里会先测量非客户区
/// （外框 − 内容区），再把外框设为 `内容区 + 非客户区`，
/// 从而保证 Flutter 画布真正等于 1280x800。
class WindowService {
  WindowService._();

  /// 期望的内容区（Flutter 画布）尺寸
  static const Size preferredClientSize = Size(1280, 800);

  /// 非客户区测量失败时的兜底值。
  ///
  /// 100% DPI 下 WS_OVERLAPPEDWINDOW 的典型值：
  /// 左右边框各 8px、标题栏 23px、上下边框各 8px。
  static const Size _fallbackFrame = Size(16, 39);

  static Size _outerSize = preferredClientSize;
  static Size _clientSize = preferredClientSize;

  /// window_manager 实际应用的外框尺寸（含标题栏 / 边框）
  static Size get size => _outerSize;

  /// 实际生效的内容区（Flutter 画布）尺寸
  static Size get clientSize => _clientSize;

  /// 初始化窗口管理器，并把内容区锁定为 [preferredClientSize]
  static Future<void> setup() async {
    await windowManager.ensureInitialized();
    await _applySize();

    final options = WindowOptions(
      size: _outerSize,
      minimumSize: _outerSize,
      maximumSize: _outerSize,
      center: true,
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  /// 首帧之后再校准一次，避免 [setup] 阶段视图尺寸尚未就绪。
  ///
  /// 该方法是幂等的：若尺寸已正确，重复设置相同的值不会产生副作用。
  static Future<void> refresh() async {
    await _applySize();
  }

  /// 固定窗口尺寸（禁用最大化 / 手动调整）
  static Future<void> applyFixedSize() async {
    await windowManager.setMaximumSize(_outerSize);
    await windowManager.setMinimumSize(_outerSize);
  }

  static Future<void> _applySize() async {
    final frame = await _measureNonClientFrame();
    final work = await _workAreaSize();

    final desiredOuter = Size(
      preferredClientSize.width + frame.width,
      preferredClientSize.height + frame.height,
    );

    // 外框不能超过工作区，否则窗口（含标题栏）会超出屏幕被裁切。
    final outer = Size(
      desiredOuter.width <= work.width ? desiredOuter.width : work.width,
      desiredOuter.height <= work.height ? desiredOuter.height : work.height,
    );

    _outerSize = outer;
    _clientSize = Size(
      (outer.width - frame.width).clamp(0.0, double.infinity),
      (outer.height - frame.height).clamp(0.0, double.infinity),
    );

    await windowManager.setSize(outer);
    await windowManager.setMinimumSize(outer);
    await windowManager.setMaximumSize(outer);
  }

  /// 测量非客户区尺寸（逻辑像素）：外框 − 内容区。
  static Future<Size> _measureNonClientFrame() async {
    try {
      final view = WidgetsBinding.instance.platformDispatcher.implicitView;
      if (view == null) {
        return _fallbackFrame;
      }

      final client = view.physicalSize / view.devicePixelRatio;
      if (client.width <= 0 || client.height <= 0) {
        return _fallbackFrame;
      }

      // window_manager 的尺寸同样是逻辑像素。
      final outer = await windowManager.getSize();
      final dw = outer.width - client.width;
      final dh = outer.height - client.height;
      if (dw < 0 || dh < 0) {
        return _fallbackFrame;
      }

      return Size(dw, dh);
    } catch (_) {
      return _fallbackFrame;
    }
  }

  static Future<Size> _workAreaSize() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final work = display.visibleSize ?? display.size;
      return Size(work.width, work.height);
    } catch (_) {
      // 获取屏幕信息失败时不做收缩，交给系统处理。
      return preferredClientSize;
    }
  }
}
