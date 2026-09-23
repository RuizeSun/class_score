import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
          title: const Text('在桌面上显示课表条'),
          subtitle: const Text('开启后会在屏幕上出现一条常驻的课程 / 倒计时提醒（不影响本窗口）'),
          value: provider.enabled,
          onChanged: provider.setEnabled,
        ),

        const SizedBox(height: SettingsLayout.sectionSpacing),
        const Divider(height: 1),
        const SizedBox(height: SettingsLayout.sectionSpacing),

        // ---- 外观 ----
        const SettingsSectionTitle(
          title: '外观',
          subtitle: '控制桌面条停靠位置、层级与不透明度',
        ),
        const SizedBox(height: 8),
        ChoiceTile<DesktopBarPosition>(
          icon: Icons.vertical_align_top,
          title: '显示位置',
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
          subtitle: const Text('开启后桌面条不响应鼠标点击，不会挡住桌面图标与其它程序'),
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
          subtitle: const Text('关闭后桌面条左侧只显示课程'),
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
          subtitle: '下面按当前时间实时渲染桌面条内容（与浮窗用的是同一套组件）',
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
  });

  final IconData icon;
  final String title;
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

/// 桌面条预览：把浮窗要显示的内容直接画在设置页里。
///
/// 用的是与浮窗完全相同的 [DesktopScheduleLive]，因此「设置改了什么」可以立刻
/// 在这里看到，不必真的开一次浮窗；裁剪 + 深色底模拟浮窗的观感。
class DesktopSchedulePreview extends StatelessWidget {
  const DesktopSchedulePreview({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DesktopBarPalette.barBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade400),
      ),
      child: const DesktopScheduleLive(),
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
