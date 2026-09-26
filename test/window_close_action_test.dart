import 'package:class_score/models/window_close_action.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('关闭按钮分流', () {
    test('锁定且未允许关闭：拦截（只提示，窗口保留）', () {
      expect(
        pickWindowCloseAction(
          locked: true,
          allowCloseWhenLocked: false,
          closeToTray: true,
        ),
        WindowCloseAction.blocked,
      );
      // 托盘开关开着也一样拦截：锁定优先。
      expect(
        pickWindowCloseAction(
          locked: true,
          allowCloseWhenLocked: false,
          closeToTray: false,
        ),
        WindowCloseAction.blocked,
      );
    });

    test('未锁定：按「关闭进托盘」开关决定收托盘还是真退出', () {
      expect(
        pickWindowCloseAction(
          locked: false,
          allowCloseWhenLocked: false,
          closeToTray: true,
        ),
        WindowCloseAction.hideToTray,
      );
      expect(
        pickWindowCloseAction(
          locked: false,
          allowCloseWhenLocked: false,
          closeToTray: false,
        ),
        WindowCloseAction.quit,
      );
    });

    test('锁定但允许关闭：同样按托盘开关走', () {
      expect(
        pickWindowCloseAction(
          locked: true,
          allowCloseWhenLocked: true,
          closeToTray: true,
        ),
        WindowCloseAction.hideToTray,
      );
      expect(
        pickWindowCloseAction(
          locked: true,
          allowCloseWhenLocked: true,
          closeToTray: false,
        ),
        WindowCloseAction.quit,
      );
    });
  });
}
