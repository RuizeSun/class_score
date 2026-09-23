import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/desktop_schedule_state.dart';
import '../../models/weather_snapshot.dart';
import '../../providers/desktop_schedule_provider.dart';
import '../motion.dart';
import 'desktop_schedule_bar.dart';
import 'desktop_schedule_countdown.dart';
import 'desktop_schedule_notice.dart';

/// 桌面条的内容分发：按当前阶段选择「常态条 / 提示横幅 / 倒计时」。
///
/// 换外观时统一走 [FadeThroughSwitcher]（旧内容先退场、新内容再进场），
/// 与设置页 / 查询页的节奏保持一致；系统开启「减少动态效果」时自动变为直切。
class DesktopScheduleWidget extends StatelessWidget {
  const DesktopScheduleWidget({
    super.key,
    required this.state,
    this.weatherLabel,
    this.weatherKind,
    this.showPreparationHint = false,
    this.scale = 1.0,
  });

  final DesktopScheduleState state;
  final String? weatherLabel;
  final WeatherKind? weatherKind;
  final bool showPreparationHint;
  final double scale;

  /// 当前该渲染哪种外观；相同 key 时不做过渡（例如图三 ↔ 图四的交替在
  /// 倒计时组件内部处理，不能让整条重新淡入淡出）。
  Object get _viewKey {
    switch (state.phase) {
      case DesktopSchedulePhase.preAlert:
        return 'pre-alert';
      case DesktopSchedulePhase.classNotice:
        return 'class-notice';
      case DesktopSchedulePhase.preCountdown:
        return 'countdown';
      default:
        return 'bar';
    }
  }

  @override
  Widget build(BuildContext context) {
    // expand: false —— 桌面条自带确定高度（图一 / 图六 52 逻辑像素），
    // 过渡容器必须按内容松约束排布，不能把条撑满整个窗口。
    return FadeThroughSwitcher(
      switchKey: _viewKey,
      duration: AppMotion.medium,
      child: _buildCurrentView(),
    );
  }

  Widget _buildCurrentView() {
    switch (state.phase) {
      // 图二：临近上课提醒
      case DesktopSchedulePhase.preAlert:
        return DesktopNoticeBanner(
          text: '即将上课',
          icon: Icons.error_outline,
          trailingIcon: Icons.meeting_room_outlined,
          scale: scale,
        );

      // 图五：正式上课提醒
      case DesktopSchedulePhase.classNotice:
        return DesktopNoticeBanner(
          text: '上课',
          icon: Icons.error_outline,
          trailingIcon: Icons.meeting_room_outlined,
          scale: scale,
        );

      // 图三 ↔ 图四：上课倒计时
      case DesktopSchedulePhase.preCountdown:
        return DesktopScheduleCountdown(
          state: state,
          showPreparationHint: showPreparationHint,
          scale: scale,
        );

      // 图一 / 图六（以及无课、课前、课后的常态）
      default:
        return DesktopScheduleBar(
          state: state,
          weatherLabel: weatherLabel,
          weatherKind: weatherKind,
          scale: scale,
        );
    }
  }
}

/// 直接订阅 [DesktopScheduleProvider] 的桌面条：
/// 主窗口里的「预览」与桌面浮窗都用它渲染，避免两处各写一遍取数逻辑。
class DesktopScheduleLive extends StatelessWidget {
  const DesktopScheduleLive({super.key, this.scale});

  /// 覆盖缩放（预览时用小尺寸展示）；为空则用用户设置值。
  final double? scale;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DesktopScheduleProvider>();

    return DesktopScheduleWidget(
      state: provider.state,
      weatherLabel: provider.weatherLabel,
      weatherKind: provider.weatherKind,
      showPreparationHint: provider.showPreparationHint,
      scale: scale ?? provider.scale,
    );
  }
}
