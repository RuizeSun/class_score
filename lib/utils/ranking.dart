/// 统计报表中「名次并列」的计算（学生榜 / 小组榜共用）。
///
/// 名次以**展示分数**（保留 1 位小数，与列表右侧分数文本一致）判定：
/// 展示分数相同即视为同名次。
///
/// [competitionRanking] 为 true（默认）时采用标准比赛名次，并列名次会占用
/// 实际排名位置，例如 `100 / 99 / 99 / 98` → `第1 / 第2 / 第2 / 第4`；
/// 为 false 时采用紧凑名次，例如 `100 / 99 / 99 / 98` → `第1 / 第2 / 第2 / 第3`。
library;

/// 分数在列表中的展示形式（1 位小数）。
///
/// 名次判定与渲染共用此格式，避免出现「显示同分却排不同名次」的观感问题。
String formatTotalScore(double score) => score.toStringAsFixed(1);

/// 一个名次分组的渲染数据。
///
/// 同一名次在界面上渲染为一个 [RankedEntry]（圆角淡色块），
/// 组内逐行展示对象（每人一行，保留逐个点击查看图表分析的能力）。
/// 「同名次合并」关闭时每个分组只含一条数据，但名次序号仍然并列。
class RankedEntry {
  const RankedEntry({required this.rank, required this.rows});

  /// 名次，从 1 开始；同名次共用同一值。
  final int rank;

  /// 该名次下的数据（学生榜 / 小组榜的原始统计 map）。
  final List<Map<String, dynamic>> rows;

  /// 该名次下的数据条数。
  int get count => rows.length;
}

double _totalScore(Map<String, dynamic> row) =>
    (row['total_score'] as num?)?.toDouble() ?? 0.0;

/// 将统计数据（学生榜 / 小组榜的总分列表）转换为名次分组。
///
/// 入参顺序不作要求：函数内按总分降序、同分保持原有相对顺序重新排列。
/// [mergeSameRank] 为 true（默认）时同分数据合并进同一分组，
/// 为 false 时每条数据独立成组，但名次序号仍然并列。
/// [competitionRanking] 控制并列后的编号方式，默认标准比赛名次（跳号）。
List<RankedEntry> buildRankedEntries(
  List<Map<String, dynamic>> rows, {
  bool mergeSameRank = true,
  bool competitionRanking = true,
}) {
  final indexed = rows.asMap().entries.toList();
  // 同分时按原始顺序排列，保证渲染顺序稳定。
  indexed.sort((a, b) {
    final cmp = _totalScore(b.value).compareTo(_totalScore(a.value));
    return cmp != 0 ? cmp : a.key.compareTo(b.key);
  });

  final entries = <RankedEntry>[];
  String? previousLabel;
  var denseRank = 0;

  for (var position = 0; position < indexed.length; position++) {
    final item = indexed[position];
    final score = _totalScore(item.value);
    final label = formatTotalScore(score);
    final isSameRank = previousLabel == label;

    if (!isSameRank) {
      denseRank++;
      previousLabel = label;
      // 标准比赛名次按并列分组第一项在排序中的实际位置编号；
      // 紧凑名次只按出现过的不同分数递增。
      final rank = competitionRanking ? position + 1 : denseRank;
      entries.add(RankedEntry(rank: rank, rows: [item.value]));
    } else if (mergeSameRank) {
      entries.last.rows.add(item.value);
    } else {
      entries.add(RankedEntry(rank: entries.last.rank, rows: [item.value]));
    }
  }

  return entries;
}
