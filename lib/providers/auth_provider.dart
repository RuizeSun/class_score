import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../database/database_helper.dart';

class AuthProvider extends ChangeNotifier {
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  bool _isPinSet = false;
  bool get isPinSet => _isPinSet;

  bool _isUnlocked = false;
  bool get isUnlocked => _isUnlocked;

  // Whether unlock was triggered by manual action (PIN or USB)
  bool _unlockedByManual = false;
  bool get isUnlockedByManual => _unlockedByManual;

  // Whether the current unlock is maintained by a USB key
  bool _unlockedByUsb = false;
  bool get isUnlockedByUsb => _unlockedByUsb;

  // Current course name if during class time
  String? _currentCourseName;
  String? get currentCourseName => _currentCourseName;

  String? _hashedPin;
  Timer? _manualUnlockTimer;
  Timer? _usbScanTimer;
  Timer? _scheduleCheckTimer;

  static const String keyFileName = '.class_key';

  String? _currentToken;
  String? get currentToken => _currentToken;

  List<Map<String, dynamic>> _usbKeys = [];
  List<Map<String, dynamic>> get usbKeys => _usbKeys;

  List<Map<String, dynamic>> _courseSchedules = [];
  List<Map<String, dynamic>> get courseSchedules => _courseSchedules;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  // Weekday names
  static const weekdayNames = {
    1: '周一',
    2: '周二',
    3: '周三',
    4: '周四',
    5: '周五',
    6: '周六',
    7: '周日',
  };

  Future<void> init() async {
    if (_isInitialized) return;

    final storedPin = await DatabaseHelper.instance.getSetting('pin_hash');
    _isPinSet = storedPin != null && storedPin.isNotEmpty;
    _hashedPin = storedPin;

    _isUnlocked = false;
    _unlockedByManual = false;
    _unlockedByUsb = false;
    _isInitialized = true;

    await loadUsbKeys();
    await loadCourseSchedules();

    if (_isPinSet) {
      _startUsbScan();
    }

    // Start schedule check timer (every 60 seconds)
    _startScheduleCheckTimer();
    // Also check immediately
    _applyScheduleRule();

    notifyListeners();
  }

  Future<void> loadUsbKeys() async {
    _usbKeys = await DatabaseHelper.instance.getUsbKeys();
    notifyListeners();
  }

  Future<void> loadCourseSchedules() async {
    _courseSchedules = await DatabaseHelper.instance.getCourseSchedules();
    _updateCurrentCourseName();
  }

  // ---- Course Schedule Management ----
  Future<void> addCourseSchedule(Map<String, dynamic> map) async {
    await DatabaseHelper.instance.insertCourseSchedule(map);
    await loadCourseSchedules();
  }

  Future<void> updateCourseSchedule(int id, Map<String, dynamic> map) async {
    await DatabaseHelper.instance.updateCourseSchedule(id, map);
    await loadCourseSchedules();
  }

  Future<void> deleteCourseSchedule(int id) async {
    await DatabaseHelper.instance.deleteCourseSchedule(id);
    await loadCourseSchedules();
  }

  // ---- PIN ----
  String _hashPin(String pin) {
    final bytes = utf8.encode(pin);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> setPin(String pin) async {
    if (pin.length != 6) return;
    _currentToken = _generateToken();
    _hashedPin = _hashPin(pin);
    await DatabaseHelper.instance.setSetting('pin_hash', _hashedPin!);
    _isPinSet = true;
    _isUnlocked = true;
    _unlockedByManual = false; // Treat initial setup as schedule-rule-based
    _startUsbScan();
    notifyListeners();
  }

  bool verifyPin(String pin) {
    if (_hashedPin == null) return false;
    return _hashPin(pin) == _hashedPin;
  }

  Future<bool> unlock(String pin) async {
    if (!verifyPin(pin)) {
      _errorMessage = 'PIN 码错误';
      notifyListeners();
      return false;
    }
    _isUnlocked = true;
    _unlockedByManual = true;
    _unlockedByUsb = false;
    _errorMessage = null;
    _currentToken = _generateToken();
    _startManualTimer();
    _startUsbScan();
    notifyListeners();
    return true;
  }

  void lock() {
    _isUnlocked = false;
    _unlockedByManual = false;
    _unlockedByUsb = false;
    _manualUnlockTimer?.cancel();
    _errorMessage = null;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  // Manual override timer: 10 minutes, then revert to schedule rule
  void _startManualTimer() {
    _manualUnlockTimer?.cancel();
    _manualUnlockTimer = Timer(const Duration(minutes: 10), () {
      if (_unlockedByManual) {
        _unlockedByManual = false;
        // Re-apply schedule rule after manual timer expires
        _applyScheduleRule();
      }
    });
  }

  // Reset timer on user activity (used when user interacts)
  void resetManualTimer() {
    if (_unlockedByManual) {
      _startManualTimer();
    }
  }

  // ---- Schedule Check Logic ----
  // Start a periodic timer to check the schedule more frequently.
  // Previously this ran every minute, which caused a noticeable delay when the
  // system time was changed while the app was running. Reducing the interval
  // to 10 seconds ensures the UI updates promptly without requiring a restart.
  void _startScheduleCheckTimer() {
    _scheduleCheckTimer?.cancel();
    // Use a shorter interval (10 seconds) for quicker refresh of unlock state.
    _scheduleCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _applyScheduleRule();
    });
  }

  /// Normalize a time string to HH:MM format (with leading zeros).
  /// E.g. "8:0" -> "08:00", "9:30" -> "09:30"
  static String _normalizeTime(String time) {
    final parts = time.split(':');
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  /// Always update the current course name based on schedule, regardless of
  /// lock/unlock state. This ensures the status bar always shows the correct
  /// course name even when the app is locked or manually unlocked.
  void _updateCurrentCourseName() {
    final now = DateTime.now();
    final weekday = now.weekday; // 1=Mon ... 7=Sun
    final currentTimeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    String? matchedCourse;

    for (final schedule in _courseSchedules) {
      if (schedule['weekday'] as int == weekday) {
        final start = _normalizeTime(schedule['start_time'] as String);
        final end = _normalizeTime(schedule['end_time'] as String);
        if (currentTimeStr.compareTo(start) >= 0 &&
            currentTimeStr.compareTo(end) < 0) {
          matchedCourse = schedule['course_name'] as String;
          break;
        }
      }
    }

    if (_currentCourseName != matchedCourse) {
      _currentCourseName = matchedCourse;
      notifyListeners();
    }
  }

  /// Check current time against course schedule and set unlock/lock accordingly.
  /// If manually unlocked, the manual timer takes precedence; after timer expires,
  /// this rule re-applies.
  void _applyScheduleRule() {
    // Always update the course name display regardless of lock state
    _updateCurrentCourseName();

    if (!_isPinSet) return;

    // If manually unlocked or USB unlocked, don't override; let manual timer expire first
    if (_unlockedByManual || _unlockedByUsb) return;

    final now = DateTime.now();
    final weekday = now.weekday; // 1=Mon ... 7=Sun
    final currentTimeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    bool inClass = false;

    for (final schedule in _courseSchedules) {
      if (schedule['weekday'] as int == weekday) {
        final start = _normalizeTime(schedule['start_time'] as String);
        final end = _normalizeTime(schedule['end_time'] as String);
        if (currentTimeStr.compareTo(start) >= 0 &&
            currentTimeStr.compareTo(end) < 0) {
          inClass = true;
          break;
        }
      }
    }

    _isUnlocked = inClass;
    notifyListeners();
  }

  /// Get the current course name for display (returns null if no class)
  String? getCurrentCourseDisplay() {
    return _currentCourseName;
  }

  // ---- USB Token ----
  String _generateToken() {
    final random = DateTime.now().millisecondsSinceEpoch;
    final hash = _hashPin('${random}_${_hashedPin ?? ''}');
    return hash;
  }

  Future<bool> writeKeyToUsb(String drivePath, {String? label}) async {
    try {
      final token = _generateToken();
      final keyFile = File('$drivePath\\$keyFileName');
      await keyFile.writeAsString(token);
      await _setHiddenAttribute(keyFile.path);
      await DatabaseHelper.instance.insertUsbKey({
        'token': token,
        'label': label ?? 'U盘密钥 ${DateTime.now().toString().substring(0, 10)}',
        'created_at': DateTime.now().toIso8601String(),
      });
      await loadUsbKeys();
      return true;
    } catch (e) {
      _errorMessage = '写入密钥失败: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> deleteUsbKey(int id) async {
    await DatabaseHelper.instance.deleteUsbKey(id);
    await loadUsbKeys();
  }

  Future<void> renameUsbKey(int id, String newLabel) async {
    await DatabaseHelper.instance.updateUsbKeyLabel(id, newLabel);
    await loadUsbKeys();
  }

  Future<void> _setHiddenAttribute(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('attrib', ['+h', path]);
      }
    } catch (_) {}
  }

  Future<void> removeKeyFromUsb(String drivePath) async {
    try {
      final keyFile = File('$drivePath\\$keyFileName');
      if (await keyFile.exists()) {
        await keyFile.delete();
      }
    } catch (_) {}
  }

  Future<bool> _hasKeyOnDrive(String drivePath) async {
    try {
      final keyFile = File('$drivePath\\$keyFileName');
      if (await keyFile.exists()) {
        final content = await keyFile.readAsString();
        final trimmed = content.trim();
        final keys = await DatabaseHelper.instance.getUsbKeys();
        for (final key in keys) {
          if (key['token'] == trimmed) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  Future<List<String>> _getRemovableDrives() async {
    final drives = <String>[];
    try {
      for (final drive in [
        'A',
        'B',
        'C',
        'D',
        'E',
        'F',
        'G',
        'H',
        'I',
        'J',
        'K',
        'L',
        'M',
        'N',
        'O',
        'P',
        'Q',
        'R',
        'S',
        'T',
        'U',
        'V',
        'W',
        'X',
        'Y',
        'Z',
      ]) {
        final path = '$drive:\\';
        try {
          if (await Directory(path).exists()) {
            if (drive != 'C') {
              drives.add(path);
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
    return drives;
  }

  Future<bool> scanUsbForKey() async {
    if (!_isPinSet) return false;
    final drives = await _getRemovableDrives();
    for (final drive in drives) {
      if (await _hasKeyOnDrive(drive)) {
        _isUnlocked = true;
        _unlockedByManual = false; // USB unlock does not grant manual override
        _unlockedByUsb = true;
        _startManualTimer();
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  void _startUsbScan() {
    _usbScanTimer?.cancel();
    _usbScanTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isUnlocked) {
        await scanUsbForKey();
      } else {
        final currentDrives = await _getRemovableDrives();
        bool keyFound = false;
        for (final drive in currentDrives) {
          if (await _hasKeyOnDrive(drive)) {
            keyFound = true;
            break;
          }
        }
        if (_unlockedByUsb || (!_unlockedByManual && keyFound)) {
          // If already USB-unlocked or newly detected key while not manually unlocked,
          // update USB unlock state.
          if (keyFound) {
            _unlockedByUsb = true;
          } else if (_unlockedByUsb) {
            // USB key was present but now removed - immediately lock
            _isUnlocked = false;
            _unlockedByManual = false;
            _unlockedByUsb = false;
            _manualUnlockTimer?.cancel();
            notifyListeners();
          }
        }
      }
    });
  }

  Future<List<String>> getAvailableUsbDrives() async {
    return _getRemovableDrives();
  }

  @override
  void dispose() {
    _manualUnlockTimer?.cancel();
    _usbScanTimer?.cancel();
    _scheduleCheckTimer?.cancel();
    super.dispose();
  }
}
