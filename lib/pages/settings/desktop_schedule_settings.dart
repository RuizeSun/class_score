import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/desktop_ball_style.dart';
import '../../models/desktop_bar_style.dart';
import '../../models/weather_snapshot.dart';
import '../../providers/desktop_schedule_provider.dart';
import '../../services/weather_service.dart';
import '../../widgets/desktop_schedule/desktop_schedule_common.dart';
import '../../widgets/desktop_schedule/desktop_schedule_widget.dart';
import 'settings_common.dart';

/// 「桌面课表」设置分项：开关、外观、提示时机与天气。
///
/// 所有设置项都直接写回 [DesktopScheduleProvider]（由它落库并推送给浮窗），
/// 页面本身不持有状态，避免出现「设置页改了、浮窗没变」的两份真相。
class DesktopScheduleSettingsView extends StatelessWidget {
  const DesktopScheduleSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DesktopScheduleProvider>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- 总开关 ----
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.desktop_windows),
          title: const Text('在桌面上显示课表胶囊'),
          subtitle: const Text('开启后会在屏幕上方居中浮出一颗常驻的课表胶囊（不影响本窗口）'),
          value: provider.enabled,
          onChanged: provider.setEnabled,
        ),

        const SizedBox(height: SettingsLayout.sectionSpacing),
        const Divider(height: 1),
        const SizedBox(height: SettingsLayout.sectionSpacing),

        // ---- 桌面悬浮球 ----
        const SettingsSectionTitle(
          title: '桌面悬浮球',
          subtitle: '桌面常驻的小圆球入口；与上面的课表开关相互独立，课表关掉时球依然在',
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.circle_outlined),
          title: const Text('在桌面显示悬浮球'),
          subtitle: const Text(
            '显示课表胶囊时球贴在胶囊右侧（两者作为整体居中于屏幕）；'
            '没有胶囊时停在屏幕右上角，可拖动调整',
          ),
          value: provider.ballEnabled,
          onChanged: provider.setBallEnabled,
        ),
        if (provider.ballEnabled) ...[
          SliderTile(
            icon: Icons.radio_button_unchecked,
            title: '悬浮球大小',
            subtitle: '相对课表胶囊的高度，并跟随「整体缩放」一起变化',
            value: provider.ballSizeRatio,
            min: minBallSizeRatio,
            max: maxBallSizeRatio,
            divisions: 12,
            label: '${(provider.ballSizeRatio * 100).round()}%',
            onChanged: provider.setBallSizeRatio,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.open_with),
            title: const Text('悬浮球位置'),
            subtitle: Text(
              provider.ballOffsetX == 0 && provider.ballOffsetY == 0
                  ? '屏幕右上角（默认）；直接拖动球即可调整，位置会自动记忆'
                  : '已拖动调整（偏移 ${provider.ballOffsetX.round()}，'
                        '${provider.ballOffsetY.round()}）；显示课表胶囊时球会贴回胶囊右侧',
            ),
            trailing: TextButton(
              onPressed: provider.resetBallOffset,
              child: const Text('重置位置'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 40, top: 4, bottom: 4),
            child: Text(
              '单击悬浮球唤起主窗口，右键是「显示 / 隐藏 / 退出」菜单；'
              '球贴着课表胶囊时位置由胶囊决定，不响应拖动。',
              style: TextStyle(
                fontSize: SettingsLayout.hintFontSize,
                color: Colors.grey.shade600,
              ),
            ),
          ),
        ],

        const SizedBox(height: SettingsLayout.sectionSpacing),
        const Divider(height: 1),
        const SizedBox(height: SettingsLayout.sectionSpacing),

        // ---- 外观（桌面态：无程序遮挡时）----
        const SettingsSectionTitle(
          title: '外观（桌面态）',
          subtitle: '无程序遮挡、只看得到桌面时的样式；胶囊水平居中悬浮，不会盖住桌面左侧的快捷方式',
        ),
        const SizedBox(height: 8),
        ChoiceTile<DesktopBarPosition>(
          icon: Icons.vertical_align_top,
          title: '显示位置',
          subtitle: '水平居中；顶部 / 中央偏上 / 底部三选一',
          value: provider.position,
          options: DesktopBarPosition.values,
          labelOf: (value) => value.label,
          onChanged: provider.setPosition,
        ),
        ChoiceTile<DesktopBarLayer>(
          icon: Icons.layers,
          title: '窗口层级',
          subtitle: '桌面级：贴在桌面、被其它窗口遮挡；置顶显示：始终盖在所有窗口之上',
          value: provider.layer,
          options: DesktopBarLayer.values,
          labelOf: (value) => value.label,
          onChanged: provider.setLayer,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.mouse),
          title: const Text('鼠标穿透'),
          subtitle: const Text(
            '开启后胶囊本身不响应鼠标点击；胶囊之外始终不响应，桌面图标照常可用',
          ),
          value: provider.clickThrough,
          onChanged: provider.setClickThrough,
        ),
        SliderTile(
          icon: Icons.opacity,
          title: '不透明度',
          value: provider.opacity,
          min: 0.3,
          max: 1.0,
          divisions: 14,
          label: '${(provider.opacity * 100).round()}%',
          onChanged: provider.setOpacity,
        ),
        SliderTile(
          icon: Icons.format_size,
          title: '整体缩放',
          value: provider.scale,
          min: 0.8,
          max: 1.6,
          divisions: 16,
          label: '${(provider.scale * 100).round()}%',
          onChanged: provider.setScale,
        ),

        const SizedBox(height: SettingsLayout.sectionSpacing),
        const Divider(height: 1),
        const SizedBox(height: SettingsLayout.sectionSpacing),

        // ---- 外观（前台态：有程序在前台时）----
        const SettingsSectionTitle(
          title: '外观（有程序在前台时）',
          subtitle:
              '开启后，检测到有程序窗口在前台（不含桌面与任务栏）时自动换用另一套位置、大小等样式；回到桌面再换回来',
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.picture_in_picture_alt_outlined),
          title: const Text('有程序在前台时使用另一套外观'),
          subtitle: const Text(
            '关闭时（默认）任何时刻都用上面的桌面态外观；开启后才按前台状态自动切换',
          ),
          value: provider.foregroundEnabled,
          onChanged: provider.setForegroundEnabled,
        ),
        if (provider.foregroundEnabled) ...[
          const SizedBox(height: 4),
          ChoiceTile<DesktopBarPosition>(
            icon: Icons.vertical_align_top,
            title: '前台显示位置',
            subtitle: '有程序在前台时胶囊的落点，同样水平居中',
            value: provider.foregroundPosition,
            options: DesktopBarPosition.values,
            labelOf: (value) => value.label,
            onChanged: provider.setForegroundPosition,
          ),
          ChoiceTile<DesktopBarLayer>(
            icon: Icons.layers,
            title: '前台窗口层级',
            subtitle: '默认置顶显示，避免被程序窗口挡住；可改回桌面级',
            value: provider.foregroundLayer,
            options: DesktopBarLayer.values,
            labelOf: (value) => value.label,
            onChanged: provider.setForegroundLayer,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.mouse),
            title: const Text('前台鼠标穿透'),
            subtitle: const Text('与桌面态的鼠标穿透相互独立'),
            value: provider.foregroundClickThrough,
            onChanged: provider.setForegroundClickThrough,
          ),
          SliderTile(
            icon: Icons.opacity,
            title: '前台不透明度',
            value: provider.foregroundOpacity,
            min: 0.3,
            max: 1.0,
            divisions: 14,
            label: '${(provider.foregroundOpacity * 100).round()}%',
            onChanged: provider.setForegroundOpacity,
          ),
          SliderTile(
            icon: Icons.format_size,
            title: '前台整体缩放',
            subtitle: '盖在程序上时通常调小一点，少挡内容',
            value: provider.foregroundScale,
            min: 0.8,
            max: 1.6,
            divisions: 16,
            label: '${(provider.foregroundScale * 100).round()}%',
            onChanged: provider.setForegroundScale,
          ),
        ],

        const SizedBox(height: SettingsLayout.sectionSpacing),
        const Divider(height: 1),
        const SizedBox(height: SettingsLayout.sectionSpacing),

        // ---- 提示时机 ----
        const SettingsSectionTitle(
          title: '提示时机',
          subtitle: '临近上课的提前提醒与横幅、倒计时交替节奏',
        ),
        const SizedBox(height: 8),
        NumberChoiceTile(
          icon: Icons.timer_outlined,
          title: '提前提醒时间',
          subtitle: '下节课开始前多久开始提醒（图二「即将上课」→ 倒计时）',
          value: provider.preClassAlertMinutes,
          options: const [1, 2, 3, 5, 8, 10],
          suffix: '分钟',
          onChanged: provider.setPreClassAlertMinutes,
        ),
        NumberChoiceTile(
          icon: Icons.campaign_outlined,
          title: '「即将上课 / 上课」横幅时长',
          subtitle: '蓝色横幅出现后停留多久再切换到下一状态',
          value: provider.noticeSeconds,
          options: const [1, 2, 3, 5],
          suffix: '秒',
          onChanged: provider.setNoticeSeconds,
        ),
        NumberChoiceTile(
          icon: Icons.sync_alt,
          title: '倒计时与提醒语交替间隔',
          subtitle: '上课倒计时的两行内容（图三 / 图四）隔多久互换一次',
          value: provider.alternateSeconds,
          options: const [2, 3, 4, 6, 8, 10],
          suffix: '秒',
          onChanged: provider.setAlternateSeconds,
        ),

        const SizedBox(height: SettingsLayout.sectionSpacing),
        const Divider(height: 1),
        const SizedBox(height: SettingsLayout.sectionSpacing),

        // ---- 天气 ----
        const SettingsSectionTitle(
          title: '天气',
          subtitle: '数据来自 Open-Meteo（免费、无需 API Key），只按城市取当前气温',
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.cloud_outlined),
          title: const Text('显示天气'),
          subtitle: const Text('关闭后胶囊左侧只显示课程'),
          value: provider.weatherEnabled,
          onChanged: provider.setWeatherEnabled,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.location_on_outlined),
          title: const Text('所在城市'),
          subtitle: Text(
            provider.weatherCity.isEmpty
                ? '未设置（不设置则不显示天气）'
                : '${provider.weatherCity}'
                      '（${provider.weatherLatitude?.toStringAsFixed(2)}, '
                      '${provider.weatherLongitude?.toStringAsFixed(2)}）',
          ),
          trailing: const Icon(Icons.search),
          onTap: () => showWeatherCityDialog(context),
        ),
        NumberChoiceTile(
          icon: Icons.schedule,
          title: '天气刷新间隔',
          value: provider.weatherRefreshMinutes,
          options: const [5, 10, 15, 30, 60, 120],
          suffix: '分钟',
          onChanged: provider.setWeatherRefreshMinutes,
        ),

        const SizedBox(height: SettingsLayout.sectionSpacing),
        const Divider(height: 1),
        const SizedBox(height: SettingsLayout.sectionSpacing),

        // ---- 预览 ----
        const SettingsSectionTitle(
          title: '预览',
          subtitle: '下面按当前时间实时渲染胶囊内容（与浮窗用的是同一套组件）',
        ),
        const SizedBox(height: 12),
        const DesktopSchedulePreview(),
      ],
    );
  }
}

/// 统一的「图标 + 标题 + 当前值」选择行，点开弹一个单选项列表。
class ChoiceTile<T> extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final T value;
  final List<T> options;
  final String Function(T value) labelOf;
  final ValueChanged<T> onChanged;

  Future<void> _pick(BuildContext context) async {
    final selected = await showDialog<T>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: options
            .map(
              (option) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, option),
                child: Row(
                  children: [
                    Icon(
                      option == value
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(labelOf(option)),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
    if (selected != null) onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Text(
        labelOf(value),
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      ),
      onTap: () => _pick(context),
    );
  }
}

/// 数值型选择行（提前提醒分钟数、横幅时长等，取值集合是离散的）。
class NumberChoiceTile extends StatelessWidget {
  const NumberChoiceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.suffix,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final int value;
  final List<int> options;
  final String suffix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ChoiceTile<int>(
      icon: icon,
      title: title,
      subtitle: subtitle,
      value: value,
      options: options,
      labelOf: (option) => '$option$suffix',
      onChanged: onChanged,
    );
  }
}

/// 滑块行（不透明度 / 缩放）。
class SliderTile extends StatelessWidget {
  const SliderTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      // 前台态的滑块带说明时保持单行，避免与右侧滑块挤在同一行换行。
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: SizedBox(
        width: 220,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                label: label,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(label, textAlign: TextAlign.end),
            ),
          ],
        ),
      ),
    );
  }
}

/// 桌面课表预览：把浮窗要显示的内容直接画在设置页里。
///
/// 用的是与浮窗完全相同的 [DesktopScheduleLive]，因此「设置改了什么」可以立刻
/// 在这里看到，不必真的开一次浮窗。外面套一层仿桌面底板并把胶囊水平居中，
/// 用来呈现胶囊的形状与「居中悬浮」的观感（窄窗口下胶囊会自动收缩，不会溢出）。
class DesktopSchedulePreview extends StatelessWidget {
  const DesktopSchedulePreview({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DesktopScheduleProvider>();
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Center(
        child: DesktopScheduleLive(
          width: DesktopBarMetrics.capsuleWidth * provider.scale,
        ),
      ),
    );
  }
}

/// 城市搜索对话框：输入城市名 → 选候选 → 写回设置并立即拉一次天气。
///
/// 之所以不让用户手填经纬度：填错一位就可能取到另一个城市的天气，而
/// Open-Meteo 的地理编码接口免费且支持中文，直接给候选列表更不容易出错。
Future<void> showWeatherCityDialog(BuildContext context) async {
  final provider = context.read<DesktopScheduleProvider>();
  final controller = TextEditingController(text: provider.weatherCity);

  List<GeocodeResult> results = const [];
  bool searching = false;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        Future<void> search() async {
          setDialogState(() {
            searching = true;
            error = null;
          });
          final found = await WeatherService.instance.searchCity(
            controller.text,
          );
          if (!ctx.mounted) return;
          setDialogState(() {
            searching = false;
            results = found;
            if (found.isEmpty) {
              error = '没有找到该城市，试试更完整的名称（例如「杭州」）';
            }
          });
        }

        return AlertDialog(
          title: const Text('设置天气城市'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: '城市名称',
                          hintText: '例如：北京',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => search(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: searching ? null : search,
                      child: const Text('搜索'),
                    ),
                  ],
                ),
                if (searching) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ],
                if (results.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (_, index) {
                        final result = results[index];
                        return ListTile(
                          dense: true,
                          title: Text(result.label),
                          subtitle: Text(
                            '${result.latitude.toStringAsFixed(2)}, '
                            '${result.longitude.toStringAsFixed(2)}',
                          ),
                          onTap: () async {
                            await provider.setWeatherLocation(
                              city: result.name,
                              latitude: result.latitude,
                              longitude: result.longitude,
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ],
        );
      },
    ),
  );

  controller.dispose();
}
