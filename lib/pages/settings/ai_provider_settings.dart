import 'package:flutter/material.dart';

import '../../services/ai_roster_service.dart';
import 'settings_common.dart';

/// AI 服务商设置（可单独压栈，也可嵌入设置中心）。
class AiProviderSettingsPage extends StatelessWidget {
  const AiProviderSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 服务商')),
      // 单独压栈时没有设置骨架提供滚动，这里自行包一层。
      body: const SingleChildScrollView(
        padding: SettingsLayout.contentPadding,
        child: AiProviderSettingsView(),
      ),
    );
  }
}

/// 设置中心内的分项视图（无 Scaffold，由设置骨架提供页头）。
class AiProviderSettingsView extends StatefulWidget {
  const AiProviderSettingsView({super.key});

  @override
  State<AiProviderSettingsView> createState() => _AiProviderSettingsViewState();
}

class _AiProviderSettingsViewState extends State<AiProviderSettingsView> {
  /// 先给出默认配置立即渲染（避免转圈 / 无尺寸导致命中测试失败），
  /// 读到数据库后再覆盖。
  AiSettings _settings = AiSettings();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _apiKeyController = TextEditingController();
  bool _obscureKey = true;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    _syncControllers();
    _load();
  }

  Future<void> _load() async {
    try {
      // 数据库不可用（测试环境等）时保留默认配置，界面照常可用。
      final s = await AiSettings.load();
      if (!mounted) return;
      setState(() {
        _settings = s;
        _syncControllers();
      });
    } catch (_) {
      // 忽略：保持默认配置
    }
  }

  void _syncControllers() {
    final s = _settings;
    final o = s.overrides[s.providerId];
    _baseUrlController.text = (o?.baseUrl ?? '').trim().isEmpty
        ? s.provider.baseUrl
        : o!.baseUrl;
    _modelController.text = (o?.model ?? '').trim().isEmpty
        ? s.provider.defaultModel
        : o!.model;
    _apiKeyController.text = o?.apiKey ?? '';
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _save({bool quiet = false}) async {
    final s = _settings;
    final o = s.overrideFor(s.providerId);
    o.baseUrl = _baseUrlController.text.trim();
    o.model = _modelController.text.trim();
    o.apiKey = _apiKeyController.text.trim();
    try {
      await s.save();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：${e.toString()}')),
      );
      return;
    }
    if (!mounted) return;
    if (!quiet) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 2)),
      );
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    await _save(quiet: true);
    try {
      final reply = await AiRosterService.instance.testConnection();
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testResult = '连接成功，模型回复：$reply';
      });
    } on AiServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = '测试失败：$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          const SettingsSectionTitle(
            title: '服务商与接口',
            subtitle: '所有服务商均使用 OpenAI 兼容的 /chat/completions 协议',
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: s.providerId,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: builtinAiProviders
                .map(
                  (p) => DropdownMenuItem(
                    value: p.id,
                    child: Text(p.name),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                s.providerId = v;
                _syncControllers();
                _testResult = null;
              });
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(
              labelText: '接口地址 baseUrl',
              border: OutlineInputBorder(),
              hintText: 'https://api.example.com/v1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelController,
            decoration: const InputDecoration(
              labelText: '模型名（需支持图片输入的视觉模型）',
              border: OutlineInputBorder(),
              hintText: '例如 deepseek-chat / qwen-vl-plus / gpt-4o-mini',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyController,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              labelText: s.provider.requiresApiKey ? 'API Key' : 'API Key（本服务可留空）',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureKey ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: SettingsLayout.sectionSpacing),
          const Divider(height: 1),
          const SizedBox(height: SettingsLayout.sectionSpacing),
          const SettingsSectionTitle(title: '连接测试'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _save(),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _testOk ? Colors.green.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _testOk ? Colors.green.shade200 : Colors.red.shade200,
                ),
              ),
              child: Text(
                _testResult!,
                style: TextStyle(
                  fontSize: 12,
                  color: _testOk ? Colors.green.shade800 : Colors.red.shade800,
                ),
              ),
            ),
          ],
          const SizedBox(height: SettingsLayout.sectionSpacing),
          const Divider(height: 1),
          const SizedBox(height: SettingsLayout.sectionSpacing),
          const SettingsSectionTitle(title: '说明'),
          const SizedBox(height: 8),
          Text(
            '识别花名册必须使用支持图片输入的视觉模型（如 qwen-vl-plus、gpt-4o-mini、glm-4v）。',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(
            'Ollama 本地部署：先在命令行运行 ollama pull 一个视觉模型（如 qwen2.5vl），'
            '接口地址填 http://localhost:11434/v1，模型名填对应模型，API Key 留空。',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
        ],
    );
  }
}
