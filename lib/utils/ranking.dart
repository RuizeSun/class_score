/// 统计报表中「同名次合并」的名次计算（学生榜 / 小组榜共用）。
///
/// 名次以**展示分数**（保留 1 位小数，与列表右侧分数文本一致）判定：
/// 展示分数相同即视为同名次，并对名次序号做紧凑编号，例如
/// `100 / 100 / 99 / 99 / 99` → `第1 / 第1 / 第2 / 第2 / 第2`。
library;

/// 分数在列表中的展示形式（1 位小数）。
///
/// 名次判定与渲染共用此格式，避免出现「显示同分却排不同名次」的观感问题。
String formatTotalScore(double score) => score.toStringAsFixed(1);

/// 一个名次分组的渲染数据。
///
/// 同一名次在界面上渲染为一个 [RankingGroup]（圆角淡色块），
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
List<RankedEntry> buildRankedEntries(
  List<Map<String, dynamic>> rows, {
  bool mergeSameRank = true,
}) {
  final indexed = rows.asMap().entries.toList();
  // 同分时按原始顺序排列，保证渲染顺序稳定。
  indexed.sort((a, b) {
    final cmp = _totalScore(b.value).compareTo(_totalScore(a.value));
    return cmp != 0 ? cmp : a.key.compareTo(b.key);
  });

  final entries = <RankedEntry>[];
  String? previousLabel;
  var rank = 0;

  for (final item in indexed) {
    final score = _totalScore(item.value);
    final label = formatTotalScore(score);
    final isSameRank = previousLabel == label;

    if (!isSameRank) {
      rank++;
      previousLabel = label;
      entries.add(RankedEntry(rank: rank, rows: [item.value]));
    } else if (mergeSameRank) {
      entries.last.rows.add(item.value);
    } else {
      entries.add(RankedEntry(rank: rank, rows: [item.value]));
    }
  }

  return entries;
}
