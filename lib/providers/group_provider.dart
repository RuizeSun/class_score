import 'package:flutter/foundation.dart';
import '../models/group.dart';
import '../database/database_helper.dart';
import '../services/backup_service.dart';

class GroupProvider extends ChangeNotifier {
  List<Group> _groups = [];
  List<Group> get groups => _groups;

  Future<void> loadGroups() async {
    final maps = await DatabaseHelper.instance.getGroups();
    _groups = maps.map((m) => Group.fromMap(m)).toList();
    notifyListeners();
  }

  Future<void> addGroup(String name) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.insertGroup({'name': name});
    await loadGroups();
  }

  Future<void> updateGroup(int id, String name) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.updateGroup(id, {'name': name});
    await loadGroups();
  }

  Future<void> deleteGroup(int id) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.deleteGroup(id);
    await loadGroups();
  }
}
