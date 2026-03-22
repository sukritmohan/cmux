/// On-screen debug log overlay for diagnosing issues without adb.
///
/// Call [ScreenLog.add] from anywhere to append a line. The overlay
/// auto-scrolls and shows the most recent 50 entries.
library;

import 'package:flutter/material.dart';

class ScreenLog {
  static final List<String> _lines = [];
  static final ValueNotifier<int> notifier = ValueNotifier(0);

  static void add(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _lines.add('[$ts] $msg');
    if (_lines.length > 50) _lines.removeAt(0);
    notifier.value++;
  }

  static List<String> get lines => List.unmodifiable(_lines);
}

class DebugLogOverlay extends StatelessWidget {
  const DebugLogOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ScreenLog.notifier,
      builder: (context, _, __) {
        if (ScreenLog.lines.isEmpty) return const SizedBox.shrink();
        return Positioned(
          left: 0,
          right: 0,
          bottom: 80,
          child: IgnorePointer(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 200),
              color: Colors.black.withAlpha(200),
              padding: const EdgeInsets.all(4),
              child: SingleChildScrollView(
                reverse: true,
                child: Text(
                  ScreenLog.lines.join('\n'),
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 9,
                    fontFamily: 'monospace',
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
