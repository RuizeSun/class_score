import 'package:class_score/models/desktop_ball_style.dart';
import 'package:class_score/widgets/desktop_schedule/desktop_schedule_common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('悬浮球落点选择', () {
    test('胶囊在屏上 → 贴胶囊右侧；否则 → 屏幕右上角', () {
      expect(pickDesktopBallMode(barVisible: true), DesktopBallMode.besideBar);
      expect(pickDesktopBallMode(barVisible: false), DesktopBallMode.corner);
    });

    test('两种落点都带可读标签（设置页说明用）', () {
      expect(DesktopBallMode.besideBar.label, '贴着课表胶囊');
      expect(DesktopBallMode.corner.label, '屏幕右上角');
    });
  });

  group('拖动偏移夹紧', () {
    test('范围内的值原样保留', () {
      expect(clampBallOffset(0), 0);
      expect(clampBallOffset(-320), -320);
      expect(clampBallOffset(480), 480);
    });

    test('越界值夹到边界：异常值不该把球送去屏幕外', () {
      expect(clampBallOffset(-99999), minBallOffset);
      expect(clampBallOffset(99999), maxBallOffset);
    });
  });

  group('推给胶囊浮窗的让位参数', () {
    test('球开着：间距 + 与胶囊等高的球径（ratio 恒为 1）', () {
      final reserve = desktopBallReserve(ballEnabled: true);
      expect(reserve.gap, DesktopBarMetrics.ballGap);
      expect(reserve.ratio, 1);
    });

    test('球关掉：归零，胶囊布局与老版本一致', () {
      final reserve = desktopBallReserve(ballEnabled: false);
      expect(reserve.gap, 0);
      expect(reserve.ratio, 0);
    });
  });

  group('「胶囊 + 悬浮球」整体居中（与原生同一套算式）', () {
    // 原生侧见 windows/runner/desktop_bar_channel.cpp 的 reserve / left 计算，
    // 悬浮球侧见 desktop_ball_window.cpp：两边都以「胶囊窗口真实矩形」为准，
    // 这里按同一公式守住「组合中心 = 屏幕中心」这条约定。
    const double workLeft = 0;
    const double workRight = 1920;

    test('让位宽度 = 间距 + 球径，胶囊左移半个让位后组合正中', () {
      const double scale = 1.3;
      final capsuleWidth = DesktopBarMetrics.capsuleWidth * scale;
      final capsuleHeight = DesktopBarMetrics.height * scale;
      // 球与胶囊等高：球径就是缩放后的胶囊高度。
      final ballDiameter = capsuleHeight;
      final reserve = DesktopBarMetrics.ballGap + ballDiameter;

      final capsuleLeft =
          workLeft + (workRight - workLeft - capsuleWidth) / 2 - reserve / 2;
      final ballLeft = capsuleLeft + capsuleWidth + DesktopBarMetrics.ballGap;

      expect(
        (capsuleLeft + ballLeft + ballDiameter) / 2,
        closeTo((workLeft + workRight) / 2, 1e-9),
      );
    });

    test('没有球时让位为 0，胶囊依旧水平居中', () {
      final capsuleWidth = DesktopBarMetrics.capsuleWidth;
      final reserve = desktopBallReserve(ballEnabled: false);
      final capsuleLeft = workLeft + (workRight - workLeft - capsuleWidth) / 2;

      expect(reserve.gap, 0);
      expect(reserve.ratio, 0);
      expect(
        capsuleLeft + capsuleWidth / 2,
        closeTo((workLeft + workRight) / 2, 1e-9),
      );
    });
  });
}
