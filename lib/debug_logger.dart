import 'package:flutter/material.dart';
import 'dart:collection';

/// Log entry types with corresponding colors
enum LogType {
  INFO,    // Blue
  SUCCESS, // Green
  ERROR,   // Red
  DATA     // Yellow for Hex values
}

/// Debug Logger Service (Singleton)
class DebugLogger {
  // Singleton instance
  static final DebugLogger _instance = DebugLogger._internal();
  factory DebugLogger() => _instance;
  DebugLogger._internal();

  // ValueNotifier for logs to enable reactive UI updates
  final ValueNotifier<List<LogEntry>> logsNotifier = ValueNotifier<List<LogEntry>>([]);

  // Maximum number of log entries to keep
  static const int maxLogEntries = 1000;

  /// Add a new log entry
  void log(String message, LogType type) {
    final timestamp = DateTime.now();
    final entry = LogEntry(timestamp, message, type);

    // Create a new list with the added entry to trigger the notifier
    final updatedLogs = List<LogEntry>.from(logsNotifier.value)..add(entry);
    
    // Keep the log size within limits
    if (updatedLogs.length > maxLogEntries) {
      updatedLogs.removeRange(0, updatedLogs.length - maxLogEntries);
    }
    
    // Update the notifier value to trigger listeners
    logsNotifier.value = updatedLogs;

    debugPrint('${_getTypePrefix(type)} $message');
  }

  /// Clear all log entries
  void clear() {
    logsNotifier.value = [];
  }

  /// Get all log entries (unmodifiable view)
  UnmodifiableListView<LogEntry> get logs => UnmodifiableListView(logsNotifier.value);

  /// Get log entries as formatted text for clipboard
  String getFormattedLogs() {
    return logsNotifier.value.map((entry) => '${_formatTimestamp(entry.timestamp)} [${_getTypePrefix(entry.type)}] ${entry.message}').join('\n');
  }

  /// Get the color for a specific log type
  Color getColorForType(LogType type) {
    switch (type) {
      case LogType.INFO:
        return Colors.blue;
      case LogType.SUCCESS:
        return Colors.green;
      case LogType.ERROR:
        return Colors.red;
      case LogType.DATA:
        return Colors.yellow;
      default:
        return Colors.white;
    }
  }

  /// Helper method to get type prefix
  String _getTypePrefix(LogType type) {
    switch (type) {
      case LogType.INFO:
        return 'INFO';
      case LogType.SUCCESS:
        return 'SUCCESS';
      case LogType.ERROR:
        return 'ERROR';
      case LogType.DATA:
        return 'DATA';
      default:
        return 'LOG';
    }
  }

  /// Helper method to format timestamp
  String _formatTimestamp(DateTime timestamp) {
    return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}.${(timestamp.millisecond ~/ 10).toString().padLeft(2, '0')}';
  }
}

/// Log entry data class
class LogEntry {
  final DateTime timestamp;
  final String message;
  final LogType type;

  LogEntry(this.timestamp, this.message, this.type);
}
