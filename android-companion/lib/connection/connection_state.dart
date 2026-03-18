/// Connection lifecycle states for the cmux bridge WebSocket.
///
/// Transitions:
///   disconnected → connecting → authenticating → connected
///   connected → reconnecting → connecting (on failure)
///   any → disconnected (on explicit disconnect)
library;

enum ConnectionStatus {
  /// No active connection.
  disconnected,

  /// TCP/WebSocket handshake in progress.
  connecting,

  /// WebSocket open, sending auth.pair.
  authenticating,

  /// Authenticated and ready for commands.
  connected,

  /// Connection lost, will retry with exponential backoff.
  reconnecting,
}
