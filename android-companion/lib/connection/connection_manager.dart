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
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:firebase_core/firebase_core.dart';

import '../notifications/attention_notification_handler.dart';
import '../notifications/fcm_token_manager.dart';
import '../notifications/firebase_config_store.dart';

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

  /// The bridge host (typically the Mac's Tailscale IP).
  String? get host => _host;

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

      // Step 3: Initialize FCM after connection is fully established.
      // Must run after connected status so debug reports can be sent back.
      await _handleFCMConfig(authResponse.result);
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

  /// Sends a raw binary frame over the WebSocket.
  ///
  /// Used for voice audio frames: the caller is responsible for prepending
  /// the 4-byte channel ID header (see [VoiceAudioFrame.encode]).
  void sendBinary(Uint8List data) {
    _channel?.sink.add(data);
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

      // Handle surface.attention directly so notifications work
      // even when the terminal screen isn't active. EventHandler also
      // receives this event but only increments the badge counter —
      // the system notification is shown here.
      if (event.event == 'surface.attention') {
        _handleAttentionEvent(event.data);
      }
    }
  }

  void _handleAttentionEvent(Map<String, dynamic> data) {
    final workspaceId = data['workspace_id'] as String? ?? '';
    final surfaceId = data['surface_id'] as String? ?? '';
    final reason = data['reason'] as String? ?? 'notification';
    final title = data['title'] as String? ?? '';

    AttentionNotificationHandler.instance.showAttention(
      workspaceId: workspaceId,
      surfaceId: surfaceId,
      reason: reason,
      title: title,
    );
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

  /// Stores Firebase config from auth response and initializes FCM.
  ///
  /// If the Mac has FCM configured, the auth.pair response includes
  /// `fcm_config` with the Firebase project details. We store them,
  /// initialize Firebase, and send our FCM token back.
  Future<void> _handleFCMConfig(Map<String, dynamic>? result) async {
    if (result == null) {
      debugPrint('[ConnectionManager] _handleFCMConfig: result is null');
      _reportFCMStatus('result_null');
      return;
    }
    final fcmConfigJson = result['fcm_config'] as Map<String, dynamic>?;
    if (fcmConfigJson == null) {
      debugPrint('[ConnectionManager] _handleFCMConfig: no fcm_config in result. keys=${result.keys.toList()}');
      _reportFCMStatus('no_fcm_config_in_result:keys=${result.keys.toList()}');
      return;
    }

    try {
      debugPrint('[ConnectionManager] _handleFCMConfig: received fcm_config=$fcmConfigJson');
      final config = FirebaseConfig.fromJson(fcmConfigJson);
      await FirebaseConfigStore.save(config);
      debugPrint('[ConnectionManager] stored Firebase config from auth response');

      // Initialize Firebase if not already done (e.g., config arrived after app start).
      debugPrint('[ConnectionManager] initializing Firebase...');
      final firebase = await _ensureFirebaseInitialized(config);
      debugPrint('[ConnectionManager] Firebase initialized=$firebase');
      if (firebase) {
        _reportFCMStatus('firebase_init_ok');
        // Wire up token sending and initialize FCM.
        FCMTokenManager.instance.onTokenAvailable = _sendFCMToken;
        debugPrint('[ConnectionManager] initializing FCMTokenManager...');
        await FCMTokenManager.instance.initialize();
        debugPrint('[ConnectionManager] FCMTokenManager initialized');
      } else {
        _reportFCMStatus('firebase_init_failed');
      }
    } catch (e, st) {
      debugPrint('[ConnectionManager] failed to handle FCM config: $e\n$st');
      _reportFCMStatus('error:$e');
    }
  }

  /// Reports FCM initialization status to the Mac for debugging.
  /// The Mac logs all incoming messages, so we can see this in system logs.
  void _reportFCMStatus(String status) {
    if (_status != ConnectionStatus.connected) return;
    sendRequest('system.fcm_debug', params: {'status': status});
  }

  /// Initializes Firebase if not already initialized.
  Future<bool> _ensureFirebaseInitialized(FirebaseConfig config) async {
    try {
      // Check if already initialized (e.g., from main.dart startup).
      await Firebase.app();
      return true;
    } catch (_) {
      // Not initialized yet — do it now.
      try {
        await Firebase.initializeApp(
          options: FirebaseOptions(
            apiKey: config.apiKey,
            appId: config.appId,
            messagingSenderId: config.senderId,
            projectId: config.projectId,
          ),
        );
        return true;
      } catch (e) {
        debugPrint('[ConnectionManager] Firebase init failed: $e');
        return false;
      }
    }
  }

  /// Sends the FCM device token to the Mac for push notification delivery.
  void _sendFCMToken(String token) {
    if (_status != ConnectionStatus.connected) return;
    debugPrint('[ConnectionManager] sending FCM token to Mac');
    sendRequest('system.update_fcm_token', params: {'fcm_token': token});
  }

  void _setStatus(ConnectionStatus newStatus) {
    if (_status == newStatus) return;
    _status = newStatus;
    _statusController.add(newStatus);
  }
}
