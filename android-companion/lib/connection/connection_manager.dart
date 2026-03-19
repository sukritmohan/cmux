/// WebSocket connection lifecycle manager for the cmux bridge.
///
/// Handles:
///   - WebSocket connect → auth.pair → system.subscribe_events flow
///   - Automatic reconnection with exponential backoff (1s → 30s)
///   - Text frame dispatch (responses vs events)
///   - Binary frame routing via [PtyDemuxer]
///   - Request/response tracking via [RequestTracker]
///   - App lifecycle awareness (pause/resume → health check)
///   - Network connectivity monitoring (skip retries when offline)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_state.dart';
import 'message_protocol.dart';
import 'pty_demuxer.dart';
import 'request_tracker.dart';

class ConnectionManager with WidgetsBindingObserver {
  /// Current connection status.
  ConnectionStatus get status => _status;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  /// Stream of status changes.
  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  final _statusController = StreamController<ConnectionStatus>.broadcast();

  /// Stream of push events from the bridge server.
  Stream<BridgeEvent> get eventStream => _eventController.stream;
  final _eventController = StreamController<BridgeEvent>.broadcast();

  /// PTY binary frame demuxer.
  final PtyDemuxer ptyDemuxer = PtyDemuxer();

  /// Tracks pending request/response pairs.
  final RequestTracker _tracker = RequestTracker();

  // Connection state
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  // Credentials
  String? _host;
  int? _port;
  String? _token;

  // Keepalive
  Timer? _pingTimer;

  // Reconnection
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  static const _minBackoff = Duration(seconds: 1);
  static const _maxBackoff = Duration(seconds: 30);
  bool _shouldReconnect = false;

  // Lifecycle tracking
  DateTime? _backgroundedAt;

  // Network connectivity
  StreamSubscription? _connectivitySub;
  bool _hasNetwork = true;

  // Health check guard against rapid foreground/background cycling
  bool _healthCheckInProgress = false;

  /// Register as a lifecycle observer so we detect app pause/resume.
  void initLifecycleObserver() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // App is going to background — stop pinging to save battery.
        _pingTimer?.cancel();
        _pingTimer = null;
        _backgroundedAt = DateTime.now();

      case AppLifecycleState.resumed:
        // App returned to foreground — reconnect immediately if needed.
        _reconnectAttempt = 0;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;

        if (_status == ConnectionStatus.connected) {
          _healthCheck();
        } else if ((_status == ConnectionStatus.reconnecting ||
                _status == ConnectionStatus.disconnected) &&
            _shouldReconnect) {
          _doConnect();
        }

        _backgroundedAt = null;

      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Configure credentials for connection. Call before [connect].
  void setCredentials({
    required String host,
    required int port,
    required String token,
  }) {
    _host = host;
    _port = port;
    _token = token;
  }

  /// Connect to the bridge server using stored credentials.
  ///
  /// Performs the full handshake: WebSocket → auth.pair → subscribe_events.
  Future<void> connect() async {
    if (_host == null || _port == null || _token == null) {
      throw StateError('Credentials not set. Call setCredentials() first.');
    }

    _shouldReconnect = true;
    _reconnectAttempt = 0;
    _startConnectivityListener();
    await _doConnect();
  }

  Future<void> _doConnect() async {
    _setStatus(ConnectionStatus.connecting);

    try {
      final uri = Uri.parse('ws://$_host:$_port');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _listenToChannel();
      _setStatus(ConnectionStatus.authenticating);

      // Step 1: Authenticate
      final authResponse = await sendRequest('auth.pair', params: {
        'token': _token!,
      });

      if (!authResponse.ok) {
        final msg = authResponse.error?.message ?? 'Authentication failed';
        throw Exception(msg);
      }

      // Step 2: Subscribe to push events
      await sendRequest('system.subscribe_events');

      _reconnectAttempt = 0;
      _startPingTimer();
      _setStatus(ConnectionStatus.connected);
    } catch (e) {
      _handleDisconnect(e);
    }
  }

  /// Send a JSON-RPC request and wait for the response.
  Future<BridgeResponse> sendRequest(
    String method, {
    Map<String, dynamic> params = const {},
  }) {
    final tracked = _tracker.track();
    final request = BridgeRequest(
      id: tracked.id,
      method: method,
      params: params,
    );

    _channel?.sink.add(request.toJson());
    return tracked.future;
  }

  /// Disconnect from the bridge server. Does not reconnect.
  void disconnect() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _cleanup();
    _setStatus(ConnectionStatus.disconnected);
  }

  /// Clean up all resources.
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySub?.cancel();
    _connectivitySub = null;
    disconnect();
    _statusController.close();
    _eventController.close();
    ptyDemuxer.dispose();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  void _listenToChannel() {
    _subscription?.cancel();
    _subscription = _channel?.stream.listen(
      _onMessage,
      onError: (error) => _handleDisconnect(error),
      onDone: () => _handleDisconnect(Exception('WebSocket closed')),
    );
  }

  void _onMessage(dynamic message) {
    if (message is String) {
      _handleTextFrame(message);
    } else if (message is List<int>) {
      _handleBinaryFrame(Uint8List.fromList(message));
    }
  }

  void _handleTextFrame(String text) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    // Try as response first (has "id" field).
    final response = BridgeResponse.fromJson(json);
    if (response != null) {
      _tracker.resolve(response);
      return;
    }

    // Try as event (has "event" field).
    final event = BridgeEvent.fromJson(json);
    if (event != null) {
      _eventController.add(event);
    }
  }

  void _handleBinaryFrame(Uint8List data) {
    ptyDemuxer.handleBinaryFrame(data);
  }

  void _handleDisconnect(Object error) {
    _cleanup();

    if (_shouldReconnect) {
      _setStatus(ConnectionStatus.reconnecting);
      _scheduleReconnect();
    } else {
      _setStatus(ConnectionStatus.disconnected);
    }
  }

  void _cleanup() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _tracker.failAll(Exception('Disconnected'));
  }

  /// Sends a periodic ping to keep the Tailscale tunnel alive.
  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      // Fire-and-forget — response is tracked and resolved normally.
      sendRequest('system.ping');
    });
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    // Don't schedule reconnect if no network — the connectivity listener
    // will trigger reconnect when network returns.
    if (!_hasNetwork) return;

    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (capped)
    final backoffMs = _minBackoff.inMilliseconds *
        pow(2, _reconnectAttempt).toInt();
    final delay = Duration(
      milliseconds: min(backoffMs, _maxBackoff.inMilliseconds),
    );

    _reconnectAttempt++;

    _reconnectTimer = Timer(delay, () {
      if (_shouldReconnect) {
        _doConnect();
      }
    });
  }

  /// Subscribe to network connectivity changes so we can pause reconnect
  /// attempts when offline and reconnect immediately when network returns.
  void _startConnectivityListener() {
    _connectivitySub?.cancel();
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork =
          !results.every((r) => r == ConnectivityResult.none);

      if (!hasNetwork) {
        // Network lost — stop wasting battery on reconnect attempts.
        _hasNetwork = false;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
      } else if (!_hasNetwork) {
        // Network restored — reconnect immediately with zero backoff.
        _hasNetwork = true;
        _reconnectAttempt = 0;
        if (_shouldReconnect && _status != ConnectionStatus.connected) {
          _doConnect();
        }
      }
    });
  }

  /// Verify the current connection is still alive after returning from
  /// background. If the ping fails or times out, tear down and reconnect.
  Future<void> _healthCheck() async {
    if (_healthCheckInProgress) return;
    _healthCheckInProgress = true;
    try {
      final response = await sendRequest('system.ping')
          .timeout(const Duration(seconds: 3));
      if (response.ok) {
        // Connection is healthy — restart the keepalive ping timer.
        _startPingTimer();
        return;
      }
    } catch (_) {
      // Ping failed or timed out — connection is stale.
    } finally {
      _healthCheckInProgress = false;
    }

    // Unhealthy: tear down and reconnect immediately.
    _cleanup();
    _reconnectAttempt = 0;
    _doConnect();
  }

  void _setStatus(ConnectionStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;
    _statusController.add(newStatus);
  }
}
