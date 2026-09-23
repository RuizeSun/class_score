import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

import 'desktop_bar_log.dart';

/// 桌面课表浮窗的**主窗口侧**编排：创建 / 等待就绪 / 显示 / 隐藏 / 关闭 / 推送内容。
///
/// 浮窗侧只做两件事（见 `pages/desktop_bar/desktop_bar_window.dart` 与
/// `services/desktop_bar_window_channel.dart`）：
/// 1. 渲染主窗口推来的状态；
/// 2. 通过**原生**通道把窗口样式设好（无边框、贴顶/贴底、透明度、鼠标穿透）。
///
/// 为什么浮窗里不用 `window_manager`：它的 MethodChannel 是进程级全局变量，
/// 第二个引擎注册会顶掉主窗口的通道；它的任务栏相关调用还依赖 COM，而浮窗引擎
/// 跑在独立线程上（未初始化 COM）。实测在浮窗里调用会直接访问冲突崩溃
/// （window_manager_plugin.dll，0xC0000005）——所以这些窗口样式改由 runner 里的
/// 原生通道完成。
class DesktopWindowService {
  DesktopWindowService._();

  /// 浮窗的启动参数：Dart 入口据此判断「这个引擎是桌面条」。
  static const String barWindowArgument = 'desktop_schedule_bar';

  /// `desktop_multi_window` 给新引擎注入的入口参数前缀。
  static const String multiWindowEntrypoint = 'multi_window';

  /// 浮窗与主窗口共用的方法名（都以 `window_` 开头，符合插件约定）。
  static const String payloadMethod = 'window_payload';
  static const String closeMethod = 'window_close';

  /// 让浮窗（重新）应用外观并显示：关闭桌面课表后再开启时，外观签名没变，
  /// 浮窗不会主动重设样式，需要这个显式指令把窗口重新显示出来。
  static const String showMethod = 'window_show';

  /// 就绪探测：浮窗注册好处理函数后立刻可用，用它判断「浮窗的 Dart 是否跑起来」。
  static const String pingMethod = 'window_ping';

  /// 首次等待浮窗就绪的上限与轮询间隔。
  ///
  /// 浮窗是独立引擎，从 `createWindow` 返回到它的 Dart 注册好处理器之间有一段
  /// 异步窗口期；这个窗口期里下发任何指令都会得到 CHANNEL_UNREGISTERED。
  static const Duration readyTimeout = Duration(seconds: 5);
  static const Duration readyPollInterval = Duration(milliseconds: 200);

  /// 浮窗不可用时的重试退避（状态每秒刷新，不退避会每秒重试并刷屏日志）。
  static const Duration retryBackoff = Duration(seconds: 5);

  /// 日志里的窗口标签：主窗口写 main，浮窗写 bar。
  static const String mainTag = 'main';
  static const String barTag = 'bar';

  /// 插件的 Dart 包装层会重写原生错误文案，只有底层通道能看到真实原因；
  /// 该前缀与 `WindowController` 内部的通道名保持一致。
  static const String _controllerChannelPrefix = 'mixin.one/window_controller/';

  static const MethodChannel _rawChannels = MethodChannel(
    'mixin.one/desktop_multi_window/channels',
  );

  static WindowController? _barWindow;

  /// 推送失败的日志只打前几条：状态每秒刷新，若浮窗一直不可用会把日志刷爆。
  static int _payloadFailureCount = 0;
  static const int _maxPayloadFailureLogs = 3;

  static Future<void> log(String message) =>
      DesktopBarLog.write(mainTag, message);

  /// 入口参数是否表明本引擎是桌面条浮窗
  /// （形如 `['multi_window', <windowId>, <windowArgument>]`）。
  static bool isBarWindow(List<String> args) =>
      args.length >= 3 &&
      args.first == multiWindowEntrypoint &&
      args[2] == barWindowArgument;

  /// 查找已存在的浮窗（应用重启后控制器会丢，需要按启动参数重新认领）。
  static Future<WindowController?> _findBarWindow() async {
    if (_barWindow != null) return _barWindow;
    try {
      for (final controller in await WindowController.getAll()) {
        if (controller.arguments == barWindowArgument) {
          _barWindow = controller;
          return controller;
        }
      }
    } catch (error) {
      await log('查找浮窗失败：$error');
    }
    return null;
  }

  /// 浮窗当前是否真实存在。
  ///
  /// 每次都重新向插件查询（并清掉本地缓存）：浮窗可能被任务管理器或系统关掉，
  /// 而主窗口手里的 [WindowController] 会变成失效句柄。
  static Future<bool> barExists() async {
    _barWindow = null;
    return await _findBarWindow() != null;
  }

  /// 创建（必要时）并等待就绪；返回是否可用。
  ///
  /// 只创建 + 探测，不做任何窗口样式设置：样式由浮窗收到内容后用自己的原生通道
  /// 应用（位置、层级、穿透、透明度都在内容快照里）。
  static Future<bool> showBar() async {
    try {
      var controller = await _findBarWindow();
      if (controller == null) {
        controller = await WindowController.create(
          const WindowConfiguration(arguments: barWindowArgument),
        );
        await log('创建浮窗 id=${controller.windowId}');
      } else {
        await log('复用已有浮窗 id=${controller.windowId}');
      }
      _barWindow = controller;

      if (!await waitUntilReady(controller)) {
        await log('浮窗就绪探测超时（窗口保留，稍后重试）');
        return false;
      }
      // 显式让浮窗重新显示：首次创建时外观还没推送（等下一条内容到达即可），
      // 而「关闭后再开启」时外观签名未变，需要这条指令把窗口重新显示出来。
      await controller.invokeMethod(showMethod);
      return true;
    } catch (error) {
      await log('创建浮窗失败：${await describeError(error, controller: _barWindow)}');
      // 注意：不把 _barWindow 置空——窗口可能已经建出来了，置空会导致下一轮
      // 又新建一个窗口，越滚越多。
      return false;
    }
  }

  /// 轮询 [pingMethod] 直到浮窗的 Dart 注册好处理器（或超时）。
  static Future<bool> waitUntilReady(WindowController controller) async {
    final deadline = DateTime.now().add(readyTimeout);
    var attempts = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempts++;
      try {
        await controller.invokeMethod(pingMethod);
        await log('浮窗就绪（探测 $attempts 次）');
        return true;
      } catch (error) {
        if (attempts == 1) {
          await log(
            '浮窗首次探测未就绪：'
            '${await describeError(error, controller: controller)}',
          );
        }
        await Future<void>.delayed(readyPollInterval);
      }
    }
    return false;
  }

  /// 推送当前要显示的内容（状态 + 天气 + 外观参数），浮窗只负责渲染。
  static Future<void> pushBarPayload(Map<String, dynamic> payload) async {
    final controller = await _findBarWindow();
    if (controller == null) return;
    try {
      await controller.invokeMethod(payloadMethod, payload);
      _payloadFailureCount = 0;
    } catch (error) {
      _payloadFailureCount++;
      if (_payloadFailureCount <= _maxPayloadFailureLogs) {
        await log(
          '推送内容失败（第 $_payloadFailureCount 次）：'
          '${await describeError(error, controller: controller)}',
        );
      } else if (_payloadFailureCount == _maxPayloadFailureLogs + 1) {
        await log('推送内容继续失败，后续不再记录');
      }
    }
  }

  /// 隐藏浮窗（关闭桌面课表时调用，保留窗口以便下次秒开）。
  static Future<void> hideBar() async {
    final controller = await _findBarWindow();
    if (controller == null) return;
    try {
      await controller.hide();
      await log('隐藏浮窗 id=${controller.windowId}');
    } catch (error) {
      await log('隐藏浮窗失败：${await describeError(error, controller: controller)}');
    }
  }

  /// 彻底关闭浮窗（应用退出时调用）。
  static Future<void> closeBar() async {
    final controller = await _findBarWindow();
    _barWindow = null;
    if (controller == null) return;
    try {
      await controller.invokeMethod(closeMethod);
      await log('已请求关闭浮窗 id=${controller.windowId}');
    } catch (error) {
      await log('关闭浮窗失败：$error');
    }
  }

  /// 把插件当前登记的所有窗口写进日志（排查「id 对不上 / 浮窗是否存在」用）。
  static Future<void> logWindowList() async {
    try {
      final windows = await WindowController.getAll();
      final summary = windows
          .map((item) => '${item.windowId}:"${item.arguments}"')
          .join(', ');
      await log('当前窗口列表：[$summary]');
    } catch (error) {
      await log('读取窗口列表失败：$error');
    }
  }

  /// 把错误翻译成「可排查的一句话」。
  ///
  /// 插件的 Dart 包装层会把原生 message 换成固定文案（例如
  /// “not accessible (may be unregistered, bidirectional pair, ...)”），
  /// 无法区分「通道没人注册」和「注册了但不可访问」；遇到**通道级**错误时
  /// 再用底层通道探一次，把插件返回的真实 message 一并记下来。
  /// 其他错误（例如浮窗处理器里抛出的异常）不回问，否则会打印出误导性的
  /// 「原生直调成功」。
  static Future<String> describeError(
    Object error, {
    WindowController? controller,
  }) async {
    final buffer = StringBuffer(error.toString());
    if (error is WindowChannelException) {
      buffer.write(' | code=${error.code} details=${error.details}');
      if (controller != null && error.code == 'CHANNEL_UNREGISTERED') {
        buffer.write(' | ${await probeNativeError(controller, pingMethod)}');
      }
    }
    return buffer.toString();
  }

  /// 绕过 Dart 包装层直调浮窗方法，返回原生错误（诊断用）。
  static Future<String> probeNativeError(
    WindowController controller,
    String method,
  ) async {
    try {
      await _rawChannels.invokeMethod('invokeMethod', {
        'channel': '$_controllerChannelPrefix${controller.windowId}',
        'method': method,
        'arguments': const <String, dynamic>{},
      });
      return '原生直调成功（说明只是调用时机太早）';
    } on PlatformException catch (error) {
      return '原生错误 code=${error.code} message=${error.message}';
    } catch (error) {
      return '原生直调异常：$error';
    }
  }
}
