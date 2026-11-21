import 'package:class_score/models/ai_selection_rule.dart';
import 'package:class_score/models/student.dart';
import 'package:class_score/services/ai_roster_service.dart';
import 'package:class_score/services/roster_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

Student _stu(int id, String name, String number) =>
    Student(id: id, name: name, studentNumber: number);

void main() {
  group('花名册编号归一化匹配', () {
    test('原样相等', () {
      expect(normalizeRosterNumberMatch('1401', '1401'), isTrue);
    });

    test('系统学号 1 可匹配花名册的 2401 / xx01 / 01 / 1', () {
      expect(normalizeRosterNumberMatch('1', '2401'), isTrue);
      expect(normalizeRosterNumberMatch('1', 'xx01'), isTrue);
      expect(normalizeRosterNumberMatch('1', '01'), isTrue);
      expect(normalizeRosterNumberMatch('1', '1'), isTrue);
    });

    test('系统学号 05 可匹配花名册的 5', () {
      expect(normalizeRosterNumberMatch('05', '5'), isTrue);
    });

    test('不同编号不匹配', () {
      expect(normalizeRosterNumberMatch('1', '2402'), isFalse);
      expect(normalizeRosterNumberMatch('12', '2401'), isFalse);
    });

    test('空值不匹配', () {
      expect(normalizeRosterNumberMatch('', '1'), isFalse);
      expect(normalizeRosterNumberMatch('1', ''), isFalse);
    });
  });

  group('规则互斥', () {
    test('空白与有手写内容互斥', () {
      final conflicts = AiSelectionRule.conflictsWhenSelecting(
        {'mark:blank'},
        'mark:anyMark',
      );
      expect(conflicts, contains('mark:blank'));
    });

    test('打勾与打叉不互斥（语义不同，可并存）', () {
      final conflicts = AiSelectionRule.conflictsWhenSelecting(
        {'mark:check'},
        'mark:cross',
      );
      expect(conflicts, isEmpty);
    });

    test('分数两档互斥', () {
      final conflicts = AiSelectionRule.conflictsWhenSelecting(
        {'threshold:atLeast'},
        'threshold:below',
      );
      expect(conflicts, contains('threshold:atLeast'));
    });
  });

  group('规则提示词', () {
    test('勾选打勾时提示词包含打勾', () {
      const rule = AiSelectionRule(marks: {RosterMark.check});
      expect(rule.toPrompt(), contains('打勾'));
    });

    test('分数阈值写入提示词', () {
      const rule = AiSelectionRule(
        marks: {RosterMark.anyMark},
        scoreThreshold: ScoreThreshold.atLeast,
        scoreValue: 80,
      );
      expect(rule.toPrompt(), contains('80'));
    });

    test('自定义条件写入提示词', () {
      const rule = AiSelectionRule(
        marks: {RosterMark.check},
        customInstruction: '只选第 2 列',
      );
      expect(rule.toPrompt(), contains('只选第 2 列'));
    });

    test('空规则有兜底文案', () {
      const rule = AiSelectionRule(marks: {});
      expect(rule.toPrompt(), isNotEmpty);
    });
  });

  group('分数阈值判定', () {
    test('≥ 与 < 三态', () {
      const atLeast = AiSelectionRule(
        marks: {RosterMark.anyMark},
        scoreThreshold: ScoreThreshold.atLeast,
        scoreValue: 60,
      );
      expect(atLeast.matchesScore(60), isTrue);
      expect(atLeast.matchesScore(59), isFalse);
      const below = AiSelectionRule(
        marks: {RosterMark.anyMark},
        scoreThreshold: ScoreThreshold.below,
        scoreValue: 60,
      );
      expect(below.matchesScore(59), isTrue);
      expect(below.matchesScore(60), isFalse);
      const none = AiSelectionRule(marks: {RosterMark.check});
      expect(none.matchesScore(100), isNull);
    });
  });

  group('条目规则过滤', () {
    test('打勾规则命中 check 条目', () {
      final entry = RosterEntry(printedNumber: '1', mark: 'check');
      expect(entry.matchesRule(const AiSelectionRule(marks: {RosterMark.check})), isTrue);
    });

    test('打勾规则不命中 blank 条目', () {
      final entry = RosterEntry(printedNumber: '1', mark: 'blank');
      expect(entry.matchesRule(const AiSelectionRule(marks: {RosterMark.check})), isFalse);
    });

    test('有手写内容规则命中数字条目', () {
      final entry = RosterEntry(printedNumber: '1', mark: 'number', value: 88);
      expect(
        entry.matchesRule(const AiSelectionRule(marks: {RosterMark.anyMark})),
        isTrue,
      );
    });

    test('空白规则命中 blank 条目', () {
      final entry = RosterEntry(printedNumber: '1', mark: 'blank');
      expect(entry.matchesRule(const AiSelectionRule(marks: {RosterMark.blank})), isTrue);
    });

    test('自定义条件命中 custom_hit', () {
      final entry = RosterEntry(printedNumber: '1', mark: 'check', customHit: true);
      expect(
        entry.matchesRule(
          const AiSelectionRule(marks: {}, customInstruction: '只选订正'),
        ),
        isTrue,
      );
    });
  });

  group('条目归属匹配', () {
    test('编号唯一命中', () {
      final students = [
        _stu(1, '张三', '1401'),
        _stu(2, '李四', '1402'),
      ];
      final result = matchEntries(
        [RosterEntry(printedNumber: '1401', mark: 'check')],
        students,
      );
      expect(result.matchedIds, {1});
      expect(result.uncertain, isEmpty);
    });

    test('带班级前缀的编号命中', () {
      final students = [_stu(5, '王五', '5')];
      final result = matchEntries(
        [RosterEntry(printedNumber: '2405', mark: 'check')],
        students,
      );
      expect(result.matchedIds, {5});
    });

    test('前缀歧义进入不确定项', () {
      final students = [
        _stu(1, '甲', '2401'),
        _stu(2, '乙', '1'),
      ];
      final result = matchEntries(
        [RosterEntry(printedNumber: '2401', mark: 'check')],
        students,
      );
      // 2401 同时命中 2401（相等）与 1（尾号相等）
      expect(result.uncertain.length, 1);
      expect(result.uncertain.first.candidates.length, 2);
    });

    test('名单外编号进入不确定项', () {
      final students = [_stu(1, '张三', '1401')];
      final result = matchEntries(
        [RosterEntry(printedNumber: '9999', mark: 'check')],
        students,
      );
      expect(result.matchedIds, isEmpty);
      expect(result.uncertain.length, 1);
      expect(result.uncertain.first.reason, contains('未在学生名单中'));
    });

    test('无编号时按姓名兜底', () {
      final students = [_stu(1, '张三', '1401')];
      final result = matchEntries(
        [RosterEntry(printedNumber: '', printedName: '张三', mark: 'check')],
        students,
      );
      expect(result.matchedIds, {1});
    });

    test('重名进入不确定项', () {
      final students = [_stu(1, '张三', '1401'), _stu(2, '张三', '1402')];
      final result = matchEntries(
        [RosterEntry(printedNumber: '', printedName: '张三', mark: 'check')],
        students,
      );
      expect(result.matchedIds, isEmpty);
      expect(result.uncertain.first.reason, contains('重名'));
    });
  });

  group('模型 JSON 解析', () {
    test('纯 JSON', () {
      final m = AiRosterService.parseModelJson('{"layout":"表格","items":[]}');
      expect(m['layout'], '表格');
    });

    test('markdown 代码块包裹', () {
      final m = AiRosterService.parseModelJson(
        '```json\n{"layout":"网格","items":[]}\n```',
      );
      expect(m['layout'], '网格');
    });

    test('前后有说明文字也能提取', () {
      final m = AiRosterService.parseModelJson(
        '识别结果如下：{"layout":"表格","items":[]} 以上。',
      );
      expect(m['layout'], '表格');
    });

    test('非法内容抛出 AiServiceException', () {
      expect(
        () => AiRosterService.parseModelJson('完全不是 JSON'),
        throwsA(isA<AiServiceException>()),
      );
    });
  });

  group('条目解析', () {
    test('从模型 map 构造条目', () {
      final e = RosterEntry.fromMap({
        'printed': '2401',
        'name': '张三',
        'mark': 'NUMBER',
        'value': 88,
        'custom_hit': true,
        'note': '第二列',
      });
      expect(e.printedNumber, '2401');
      expect(e.mark, 'number');
      expect(e.value, 88);
      expect(e.customHit, isTrue);
    });

    test('缺失字段有默认值', () {
      final e = RosterEntry.fromMap({});
      expect(e.printedNumber, '');
      expect(e.mark, 'other');
      expect(e.value, isNull);
      expect(e.customHit, isFalse);
    });

    test('标记中文描述', () {
      expect(RosterEntry(printedNumber: '1', mark: 'check').markLabel(), '打勾');
      expect(RosterEntry(printedNumber: '1', mark: 'cross').markLabel(), '打叉');
      expect(RosterEntry(printedNumber: '1', mark: 'triangle').markLabel(), '三角形');
      expect(RosterEntry(printedNumber: '1', mark: 'blank').markLabel(), '空白');
    });
  });

  group('AI 设置持久化编解码', () {
    test('默认 provider 为 deepseek 且未配置', () {
      final s = AiSettings();
      expect(s.providerId, 'deepseek');
      expect(s.effectiveBaseUrl, 'https://api.deepseek.com/v1');
      expect(s.isReady, isFalse);
    });

    test('Ollama 可不填 Key', () {
      final s = AiSettings(providerId: 'ollama');
      s.overrideFor('ollama').model = 'qwen2.5vl';
      expect(s.isReady, isTrue);
    });

    test('编码后解码保持一致', () {
      final s = AiSettings(providerId: 'qwen');
      s.overrideFor('qwen')
        ..apiKey = 'sk-test'
        ..model = 'qwen-vl-max';
      final restored = AiSettings.decode(s.encode());
      expect(restored.providerId, 'qwen');
      expect(restored.effectiveApiKey, 'sk-test');
      expect(restored.effectiveModel, 'qwen-vl-max');
    });

    test('损坏 JSON 回退默认设置', () {
      final s = AiSettings.decode('not-json');
      expect(s.providerId, 'deepseek');
    });
  });

  group('规则序列化', () {
    test('toMap / fromMap 往返', () {
      const rule = AiSelectionRule(
        marks: {RosterMark.check, RosterMark.triangle},
        scoreThreshold: ScoreThreshold.below,
        scoreValue: 70,
        customInstruction: '忽略第一行',
      );
      final restored = AiSelectionRule.fromMap(rule.toMap());
      expect(restored.marks, rule.marks);
      expect(restored.scoreThreshold, ScoreThreshold.below);
      expect(restored.scoreValue, 70);
      expect(restored.customInstruction, '忽略第一行');
    });
  });
}
