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
    BackupService.instance.scheduleBackup();
    await DatabaseHelper.instance.insertGroup({'name': name});
    await loadGroups();
  }

  Future<void> updateGroup(int id, String name) async {
    await BackupService.instance.createBackup();
    await DatabaseHelper.instance.updateGroup(id, {'name': name});
    await loadGroups();
  }

  Future<void> deleteGroup(int id) async {
    // 删小组会连同组内学生一起删掉（见 DatabaseHelper.deleteGroup）：必须先有快照。
    await BackupService.instance.createBackup(force: true);
    await DatabaseHelper.instance.deleteGroup(id);
    await loadGroups();
  }
}
