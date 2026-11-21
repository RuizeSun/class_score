import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../database/database_helper.dart';
import '../models/ai_selection_rule.dart';

/// AI 服务商配置。
class AiProviderConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String defaultModel;
  final bool requiresApiKey;

  const AiProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.defaultModel,
    this.requiresApiKey = true,
  });
}

/// 内置服务商预设（OpenAI 兼容协议；baseUrl / model / apiKey 均可改）。
const List<AiProviderConfig> builtinAiProviders = [
  AiProviderConfig(
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
  ),
  AiProviderConfig(
    id: 'ollama',
    name: 'Ollama（本地）',
    baseUrl: 'http://localhost:11434/v1',
    defaultModel: '',
    requiresApiKey: false,
  ),
  AiProviderConfig(
    id: 'qwen',
    name: '通义千问 Qwen',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-vl-plus',
  ),
  AiProviderConfig(
    id: 'openai',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
  ),
  AiProviderConfig(
    id: 'openrouter',
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'google/gemini-2.0-flash-001',
  ),
  AiProviderConfig(
    id: 'minimax',
    name: 'MiniMax',
    baseUrl: 'https://api.minimax.chat/v1',
    defaultModel: 'abab6.5s-chat',
  ),
  AiProviderConfig(
    id: 'mimo',
    name: 'MiMo',
    baseUrl: 'https://api.xiaomimimo.com/v1',
    defaultModel: 'MiMo-VL-7B',
  ),
  AiProviderConfig(
    id: 'custom',
    name: '自定义',
    baseUrl: '',
    defaultModel: '',
  ),
];

/// 每个 provider 的用户可改配置。
class AiProviderOverride {
  String baseUrl;
  String model;
  String apiKey;

  AiProviderOverride({this.baseUrl = '', this.model = '', this.apiKey = ''});

  Map<String, dynamic> toMap() => {
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': apiKey,
  };

  factory AiProviderOverride.fromMap(Map<String, dynamic> map) {
    return AiProviderOverride(
      baseUrl: (map['baseUrl'] as String?) ?? '',
      model: (map['model'] as String?) ?? '',
      apiKey: (map['apiKey'] as String?) ?? '',
    );
  }
}

/// AI 设置（持久化到 app_settings 表，key = ai_roster_settings）。
class AiSettings {
  String providerId;
  final Map<String, AiProviderOverride> overrides;

  AiSettings({
    this.providerId = 'deepseek',
    Map<String, AiProviderOverride>? overrides,
  }) : overrides = overrides ?? {};

  static const String settingsKey = 'ai_roster_settings';

  AiProviderConfig get provider => builtinAiProviders
      .firstWhere((p) => p.id == providerId, orElse: () => builtinAiProviders.first);

  AiProviderOverride overrideFor(String id) {
    return overrides[id] ??= AiProviderOverride();
  }

  String get effectiveBaseUrl {
    final o = overrides[providerId];
    final v = (o?.baseUrl ?? '').trim();
    if (v.isNotEmpty) return v;
    return provider.baseUrl;
  }

  String get effectiveModel {
    final o = overrides[providerId];
    final v = (o?.model ?? '').trim();
    if (v.isNotEmpty) return v;
    return provider.defaultModel;
  }

  String get effectiveApiKey => (overrides[providerId]?.apiKey ?? '').trim();

  bool get isReady {
    if (effectiveBaseUrl.isEmpty || effectiveModel.isEmpty) return false;
    if (provider.requiresApiKey && effectiveApiKey.isEmpty) return false;
    return true;
  }

  Map<String, dynamic> toMap() => {
    'providerId': providerId,
    'overrides': overrides.map((k, v) => MapEntry(k, v.toMap())),
  };

  factory AiSettings.fromMap(Map<String, dynamic> map) {
    final raw = (map['overrides'] as Map?)?.cast<String, dynamic>() ?? {};
    return AiSettings(
      providerId: (map['providerId'] as String?) ?? 'deepseek',
      overrides: raw.map(
        (k, v) => MapEntry(
          k,
          AiProviderOverride.fromMap((v as Map).cast<String, dynamic>()),
        ),
      ),
    );
  }

  String encode() => jsonEncode(toMap());

  static AiSettings decode(String raw) {
    try {
      return AiSettings.fromMap(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AiSettings();
    }
  }

  Future<void> save() async {
    await DatabaseHelper.instance.setSetting(settingsKey, encode());
  }

  static Future<AiSettings> load() async {
    final raw = await DatabaseHelper.instance.getSetting(settingsKey);
    return raw == null ? AiSettings() : AiSettings.decode(raw);
  }
}

/// 模型转录出的一个格子条目。
class RosterEntry {
  final String printedNumber;
  final String printedName;
  final String mark;
  final double? value;
  final bool customHit;
  final String note;

  RosterEntry({
    required this.printedNumber,
    this.printedName = '',
    required this.mark,
    this.value,
    this.customHit = false,
    this.note = '',
  });

  /// 规则过滤：该条目是否符合用户规则（应被选中的格子）。
  bool matchesRule(AiSelectionRule rule) {
    final m = mark.toLowerCase();
    for (final rm in rule.marks) {
      switch (rm) {
        case RosterMark.check:
          if (m.contains('check')) return true;
          break;
        case RosterMark.cross:
          if (m.contains('cross')) return true;
          break;
        case RosterMark.triangle:
          if (m.contains('triangle')) return true;
          break;
        case RosterMark.blank:
          if (m.contains('blank')) return true;
          break;
        case RosterMark.anyMark:
          if (!m.contains('blank')) return true;
          break;
      }
    }
    if (rule.scoreThreshold != ScoreThreshold.none && value != null) {
      final ok = rule.matchesScore(value!);
      if (ok == true) return true;
    }
    if (rule.customInstruction.trim().isNotEmpty && customHit) {
      return true;
    }
    return false;
  }

  /// 标记的中文描述（结果展示用）。
  String markLabel() {
    switch (mark.toLowerCase()) {
      case 'check':
        return '打勾';
      case 'cross':
        return '打叉';
      case 'triangle':
        return '三角形';
      case 'blank':
        return '空白';
      case 'number':
        return value == null ? '数字' : '数字 $value';
      default:
        return note.isEmpty ? '其他' : note;
    }
  }

  factory RosterEntry.fromMap(Map<String, dynamic> map) {
    return RosterEntry(
      printedNumber: (map['printed'] as String?) ?? '',
      printedName: (map['name'] as String?) ?? '',
      mark: ((map['mark'] as String?) ?? 'other').toLowerCase(),
      value: (map['value'] as num?)?.toDouble(),
      customHit: (map['custom_hit'] as bool?) ?? false,
      note: (map['note'] as String?) ?? '',
    );
  }
}

/// AI 服务调用结果。
class AiRosterResponse {
  final List<RosterEntry> entries;
  final String layout;
  final String raw;

  AiRosterResponse({
    required this.entries,
    required this.layout,
    required this.raw,
  });
}

/// AI 推理异常（带分类的中文信息）。
class AiServiceException implements Exception {
  final String message;
  AiServiceException(this.message);
  @override
  String toString() => message;
}

/// 花名册 AI 识别服务。
class AiRosterService {
  AiRosterService._();

  static final AiRosterService instance = AiRosterService._();

  /// 历史轮次（用于「提出进一步要求」多轮对话）。
  final List<Map<String, dynamic>> _history = [];

  void resetHistory() => _history.clear();

  /// 构建系统提示词（版式无关）。
  String buildSystemPrompt({
    required AiSelectionRule rule,
    required List<String> candidateLines,
  }) {
    final sb = StringBuffer();
    sb.writeln('你是一个专业的班级花名册识别助手。用户会给你一张花名册/作业登记表的照片。');
    sb.writeln('');
    sb.writeln('图片版式说明：图片可能是');
    sb.writeln('1. 学号-姓名表格：每行有印刷体学号、姓名、性别列和若干手写标记列；');
    sb.writeln('2. 编号网格：每个格子有印刷体序号（1、2、3...），格内可能有手写内容；');
    sb.writeln('3. 其他任意版式。');
    sb.writeln('请先判断实际版式，不要假设固定结构。');
    sb.writeln('');
    sb.writeln('关键要求：');
    sb.writeln('- 每个学生位置由印刷体学号或序号标识，请原样转录印刷编号（保留班级前缀，如 2401、xx01、01）。');
    sb.writeln('- 姓名可能模糊、被遮挡或不可辨认，忽略即可，以编号为准。');
    sb.writeln('- 格内手写内容可能是：勾号（check）、叉号（cross）、三角形（triangle）、空白（blank）、数字分数（number）、其他符号（other）。');
    sb.writeln('- 图片底部可能有图例说明（如「完成：勾 订正：三角 未完成：叉」），据此理解标记含义。');
    sb.writeln('- 空白格也必须输出（mark=blank），不要遗漏。');
    sb.writeln('- 只输出一个 JSON，不要输出 markdown 代码块以外的说明文字。');
    sb.writeln('');
    sb.writeln('候选学生名单（学号 姓名）——仅供参考，帮助你分辨编号：');
    for (final line in candidateLines.take(200)) {
      sb.writeln('  $line');
    }
    sb.writeln('');
    sb.writeln('用户的选中规则：${rule.toPrompt()}');
    sb.writeln('');
    sb.writeln('输出格式（严格 JSON）：');
    sb.writeln('{"layout":"表格或网格或其他描述","items":[{"printed":"原样印刷编号","name":"姓名或空","mark":"check|cross|triangle|blank|number|other","value":null,"custom_hit":false,"note":"补充说明或空"}]}');
    sb.writeln('');
    sb.writeln('custom_hit：用户有额外自定义条件时该格是否满足，无自定义条件时一律 false。');
    sb.writeln('value：mark=number 时填手写数字（可为小数），其他 mark 一律 null。');
    return sb.toString();
  }

  String _userText(bool withHistory, String followUp) {
    final sb = StringBuffer();
    sb.writeln('请识别这张花名册图片，按系统提示词要求输出 JSON。');
    if (withHistory && followUp.trim().isNotEmpty) {
      sb.writeln('用户补充要求：${followUp.trim()}');
    }
    return sb.toString();
  }

  /// 主入口：识别裁剪后的图像 bytes。
  Future<AiRosterResponse> recognize({
    required Uint8List imageBytes,
    required AiSelectionRule rule,
    required List<String> candidateLines,
    String followUp = '',
  }) async {
    final settings = await AiSettings.load();
    if (!settings.isReady) {
      throw AiServiceException('AI 服务未配置完整，请先到「设置 → AI 服务商」完成配置');
    }

    final system = buildSystemPrompt(rule: rule, candidateLines: candidateLines);
    final isFirstRound = _history.isEmpty;
    final userText = _userText(!isFirstRound, followUp);

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
    ];
    messages.addAll(_history);
    final userContent = <Map<String, dynamic>>[
      {'type': 'text', 'text': userText},
      {
        'type': 'image_url',
        'image_url': {
          'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
        },
      },
    ];
    messages.add({'role': 'user', 'content': userContent});

    final body = jsonEncode({
      'model': settings.effectiveModel,
      'messages': messages,
      'temperature': 0.1,
    });

    final raw = await _postChat(settings, body);

    _history.add({'role': 'user', 'content': userContent});
    _history.add({'role': 'assistant', 'content': raw});

    final parsed = parseModelJson(raw);
    final entries = <RosterEntry>[];
    final items = parsed['items'];
    if (items is List) {
      for (final item in items) {
        if (item is Map) {
          entries.add(RosterEntry.fromMap(item.cast<String, dynamic>()));
        }
      }
    }
    return AiRosterResponse(
      entries: entries,
      layout: (parsed['layout'] as String?) ?? '',
      raw: raw,
    );
  }

  /// 测试连接（发一条最小请求）。
  Future<String> testConnection() async {
    final settings = await AiSettings.load();
    if (!settings.isReady) {
      throw AiServiceException(
        '配置不完整：请填写 baseUrl、模型名${settings.provider.requiresApiKey ? '和 API Key' : ''}',
      );
    }
    final body = jsonEncode({
      'model': settings.effectiveModel,
      'messages': [
        {'role': 'user', 'content': '回复 OK'},
      ],
      'max_tokens': 8,
    });
    final raw = await _postChat(settings, body);
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final choices = j['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        final msg = (choices.first as Map)['message'] as Map;
        return ((msg['content'] as String?) ?? '').trim();
      }
    } catch (_) {
      // 忽略解析错误，返回原始片段
    }
    return raw.length > 100 ? raw.substring(0, 100) : raw;
  }

  Future<String> _postChat(AiSettings settings, String body) async {
    final base = settings.effectiveBaseUrl;
    final uri = Uri.parse(
      base.endsWith('/') ? '${base}chat/completions' : '$base/chat/completions',
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      final key = settings.effectiveApiKey;
      if (key.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      }
      req.add(utf8.encode(body));
      final resp = await req.close().timeout(
        const Duration(seconds: 90),
        onTimeout: () =>
            throw AiServiceException('请求超时（90 秒），请检查网络或稍后重试'),
      );
      final respBody = await utf8.decoder.bind(resp).join();

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw AiServiceException(
          '鉴权失败（${resp.statusCode}）：请检查 API Key 是否正确',
        );
      }
      if (resp.statusCode == 429) {
        throw AiServiceException('请求过于频繁（429）：请稍后重试');
      }
      if (resp.statusCode >= 400) {
        final detail =
            respBody.length > 200 ? respBody.substring(0, 200) : respBody;
        throw AiServiceException(
          '服务返回错误（${resp.statusCode}）：$detail',
        );
      }
      return respBody;
    } on SocketException catch (e) {
      throw AiServiceException('网络连接失败：${e.message}');
    } on HttpException {
      throw AiServiceException('网络请求失败，请检查 baseUrl 是否正确');
    } on TimeoutException {
      throw AiServiceException('请求超时，请检查网络或稍后重试');
    } finally {
      client.close();
    }
  }

  /// 解析模型返回的 JSON（容错：剥离 markdown 代码块、截取花括号主体）。
  static Map<String, dynamic> parseModelJson(String raw) {
    var text = raw.trim();
    final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
    final m = fence.firstMatch(text);
    if (m != null) {
      text = m.group(1)!.trim();
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      text = text.substring(start, end + 1);
    }
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      throw AiServiceException(
        '模型返回内容无法解析为 JSON，请重试或换用更强的模型。原始内容：${raw.length > 300 ? raw.substring(0, 300) : raw}',
      );
    }
  }
}
