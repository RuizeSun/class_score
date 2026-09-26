/// 点击窗口关闭按钮时该做什么。
///
/// 三个分支对应三种既有语义，抽成枚举是为了让「关闭」这件事在设置页与主页
/// 之间只有一份定义。
enum WindowCloseAction {
  /// 锁定态且未允许关闭：只提示，窗口原样保留。
  blocked,

  /// 收进系统托盘：窗口隐藏，程序继续在后台运行（桌面课表与悬浮球照常显示）。
  hideToTray,

  /// 真正退出：先收掉桌面上的子窗口（课表胶囊、悬浮球），再销毁主窗口。
  quit,
}

/// 关闭按钮的分流规则。
///
/// 与「未解锁时允许关闭窗口」「关闭窗口时最小化到托盘」两个开关一一对应。
/// 抽成纯函数的原因：这三条分支全在窗口动作里，widget 测试很难覆盖，
/// 而分流规则本身是纯逻辑，值得直接断言。
WindowCloseAction pickWindowCloseAction({
  required bool locked,
  required bool allowCloseWhenLocked,
  required bool closeToTray,
}) {
  if (locked && !allowCloseWhenLocked) return WindowCloseAction.blocked;
  return closeToTray ? WindowCloseAction.hideToTray : WindowCloseAction.quit;
}
