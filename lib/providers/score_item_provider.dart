import 'package:flutter/foundation.dart';
import '../models/score_item.dart';
import '../database/database_helper.dart';
import '../services/backup_service.dart';

class ScoreItemProvider extends ChangeNotifier {
  List<ScoreItem> _items = [];
  List<ScoreItem> get items => _items;

  Future<void> loadItems() async {
    final maps = await DatabaseHelper.instance.getScoreItems();
    _items = maps.map((m) => ScoreItem.fromMap(m)).toList();
    notifyListeners();
  }

  Future<void> addItem(ScoreItem item) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.insertScoreItem(item.toMap());
    await loadItems();
  }

  Future<void> updateItem(int id, ScoreItem item) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.updateScoreItem(id, item.toMap());
    await loadItems();
  }

  Future<void> deleteItem(int id) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.deleteScoreItem(id);
    await loadItems();
  }
}
