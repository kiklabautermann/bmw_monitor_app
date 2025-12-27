import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'debug_logger.dart';

/// Debug Console Widget
class DebugConsole extends StatefulWidget {
  final BuildContext? scaffoldContext;

  const DebugConsole({super.key, this.scaffoldContext});

  @override
  State<DebugConsole> createState() => _DebugConsoleState();
}

class _DebugConsoleState extends State<DebugConsole> {
  final DebugLogger _logger = DebugLogger();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Setup listener for auto-scrolling when logs change
    _logger.logsNotifier.addListener(_handleLogsChanged);
  }

  @override
  void dispose() {
    _logger.logsNotifier.removeListener(_handleLogsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleLogsChanged() {
    // Auto-scroll to bottom when new logs are added
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _clearLogs() {
    _logger.clear();
  }

  void _copyToClipboard() {
    final logs = _logger.getFormattedLogs();
    Clipboard.setData(ClipboardData(text: logs));

    // Fallback: Show a simple dialog since ScaffoldMessenger is not available in Dialog context
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Success'),
        content: const Text('Logs copied to clipboard'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 250,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[800]!, width: 1),
      ),
      child: Column(
        children: [
          // Console header with buttons
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              children: [
                const Text(
                  'DEBUG CONSOLE',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  tooltip: 'Clear Log',
                  onPressed: _clearLogs,
                  color: Colors.white,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy to Clipboard',
                  onPressed: _copyToClipboard,
                  color: Colors.white,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          // Log entries with ValueListenableBuilder for real-time updates
          Expanded(
            child: ValueListenableBuilder<List<LogEntry>>(
              valueListenable: _logger.logsNotifier,
              builder: (context, logs, _) {
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(8),
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    final entry = logs[index];
                    return Text(
                      '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}.${(entry.timestamp.millisecond ~/ 10).toString().padLeft(2, '0')} [${entry.type.toString().split('.').last}] ${entry.message}',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: _logger.getColorForType(entry.type),
                      ),
                    );
                  },
                );
              }
            ),
          ),
        ],
      ),
    );
  }
}
