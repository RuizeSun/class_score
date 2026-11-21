/// 花名册编号归一化匹配与规则过滤引擎。
///
/// 模型只负责"感知转录"（每个格子的印刷编号 + 手写标记 + 数值），
/// 编号匹配、规则过滤、前缀归一等决策全部在本地完成，保证可测可控。
library;

import '../models/student.dart';
import 'ai_roster_service.dart';

/// 归一化匹配单个编号：花名册印刷编号 [printed] 是否对应系统学号 [sys]。
///
/// 规则（按顺序尝试，命中即 true）：
/// 1. 原样相等（去空格、忽略大小写）
/// 2. 数值等值：两侧数字串转 int 相等（容忍前导零、班级前缀、字母前缀）
///    如 sys=1 对应 printed=2401 / xx01 / 01 / 1
/// 3. 末段数字等值：printed 末尾连续数字段与 sys 数值相等
bool normalizeRosterNumberMatch(String sys, String printed) {
  final s = sys.trim();
  final p = printed.trim();
  if (s.isEmpty || p.isEmpty) return false;
  if (s.toLowerCase() == p.toLowerCase()) return true;

  final sNum = _digitsOnly(s);
  final pNum = _digitsOnly(p);
  if (sNum.isEmpty || pNum.isEmpty) return false;

  // 数值等值（容忍前导零）
  final sVal = int.tryParse(sNum);
  final pVal = int.tryParse(pNum);
  if (sVal != null && pVal != null && sVal == pVal) return true;

  // 前后缀匹配：一侧是另一侧的后一段数字（如 2401 ↔ 1 / 01）
  // 要求被省略的前缀至少有 2 位（班级/年份前缀），避免 11 被当成 1 号。
  if (_isSuffixWithPrefix(pNum, sNum)) return true;
  if (_isSuffixWithPrefix(sNum, pNum)) return true;

  // 完整数字串的末段匹配（printed 含字母或分隔符时，如 xx-2401）
  final pTail = _lastDigitRun(p);
  final sTail = _lastDigitRun(s);
  if (pTail != pNum && _isSuffixWithPrefix(pTail, sNum)) return true;
  if (sTail != sNum && _isSuffixWithPrefix(sTail, pNum)) return true;

  return false;
}

/// [full] 是否以 [suffix] 结尾，且被省略的前缀长度 >= 2。
bool _isSuffixWithPrefix(String full, String suffix) {
  if (suffix.isEmpty || full.isEmpty) return false;
  if (full.length - suffix.length < 2) return false;
  return full.endsWith(suffix);
}
String _digitsOnly(String v) => v
    .split('')
    .where((c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39)
    .join();

String _lastDigitRun(String v) {
  final sb = StringBuffer();
  for (var i = v.length - 1; i >= 0; i--) {
    final c = v.codeUnitAt(i);
    if (c >= 0x30 && c <= 0x39) {
      sb.write(v[i]);
    } else if (sb.isNotEmpty) {
      break;
    }
  }
  return sb.toString().split('').reversed.join();
}

/// 模型转录出的一个格子条目 → 匹配结果分类。
class RosterMatchResult {
  final Set<int> matchedIds;
  final List<RosterUncertainItem> uncertain;

  RosterMatchResult({required this.matchedIds, required this.uncertain});
}

/// 不确定项。
class RosterUncertainItem {
  final String printedNumber;
  final String printedName;
  final String mark;
  final String reason;
  final List<Student> candidates;

  RosterUncertainItem({
    required this.printedNumber,
    required this.printedName,
    required this.mark,
    required this.reason,
    this.candidates = const [],
  });
}

/// 匹配引擎主入口：把转录条目归属到学生。
RosterMatchResult matchEntries(
  List<RosterEntry> entries,
  List<Student> students,
) {
  final matched = <int>{};
  final uncertain = <RosterUncertainItem>[];

  for (final e in entries) {
    if (e.printedNumber.trim().isEmpty && e.printedName.trim().isEmpty) {
      continue;
    }
    if (e.printedNumber.trim().isNotEmpty) {
      final hits = students
          .where((s) =>
              s.studentNumber.isNotEmpty &&
              normalizeRosterNumberMatch(s.studentNumber, e.printedNumber))
          .toList();
      if (hits.length == 1) {
        matched.add(hits.first.id!);
        continue;
      }
      if (hits.length > 1) {
        uncertain.add(RosterUncertainItem(
          printedNumber: e.printedNumber,
          printedName: e.printedName,
          mark: e.markLabel(),
          reason: '编号 ${e.printedNumber} 命中 ${hits.length} 名学生（前缀歧义）',
          candidates: hits,
        ));
        continue;
      }
      final nameHit = _matchByName(students, e.printedName);
      if (nameHit.isNotEmpty) {
        if (nameHit.length == 1) {
          matched.add(nameHit.first.id!);
          continue;
        }
        uncertain.add(RosterUncertainItem(
          printedNumber: e.printedNumber,
          printedName: e.printedName,
          mark: e.markLabel(),
          reason: '重名 ${e.printedName}（${nameHit.length} 人）',
          candidates: nameHit,
        ));
        continue;
      }
      uncertain.add(RosterUncertainItem(
        printedNumber: e.printedNumber,
        printedName: e.printedName,
        mark: e.markLabel(),
        reason: '花名册编号 ${e.printedNumber} 未在学生名单中找到对应学生',
      ));
      continue;
    }
    final nameHit = _matchByName(students, e.printedName);
    if (nameHit.length == 1) {
      matched.add(nameHit.first.id!);
    } else if (nameHit.isEmpty) {
      uncertain.add(RosterUncertainItem(
        printedNumber: e.printedNumber,
        printedName: e.printedName,
        mark: e.markLabel(),
        reason: '姓名 ${e.printedName} 不在学生名单中',
      ));
    } else {
      uncertain.add(RosterUncertainItem(
        printedNumber: e.printedNumber,
        printedName: e.printedName,
        mark: e.markLabel(),
        reason: '重名 ${e.printedName}（${nameHit.length} 人）',
        candidates: nameHit,
      ));
    }
  }
  return RosterMatchResult(matchedIds: matched, uncertain: uncertain);
}

List<Student> _matchByName(List<Student> students, String name) {
  final n = name.trim();
  if (n.isEmpty) return const [];
  return students.where((s) => s.name.trim() == n).toList();
}
