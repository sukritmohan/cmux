/// QR code pairing screen.
///
/// Full-screen dark camera view with MobileScanner for scanning
/// the cmux bridge QR code. On successful scan, stores credentials
/// and navigates to the home screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/providers.dart';

class PairingScreen extends ConsumerStatefulWidget {
  /// Whether this is an intentional re-scan from the home screen.
  final bool rescan;

  const PairingScreen({super.key, this.rescan = false});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _processing = false;
  String? _errorMessage;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;

    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue == null || rawValue.isEmpty) continue;

      final pairing = ref.read(pairingServiceProvider);
      final credentials = pairing.parseQrPayload(rawValue);

      if (credentials == null) {
        setState(() => _errorMessage = 'Invalid QR code. Use the cmux Settings QR.');
        continue;
      }

      setState(() {
        _processing = true;
        _errorMessage = null;
      });

      await pairing.saveCredentials(credentials);

      // Disconnect existing connection before setting new credentials
      // so HomeScreen's _initConnection reconnects cleanly.
      final manager = ref.read(connectionManagerProvider);
      if (widget.rescan) {
        manager.disconnect();
      }
      manager.setCredentials(
        host: credentials.host,
        port: credentials.port,
        token: credentials.token,
      );

      if (mounted) {
        context.go('/home');
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: widget.rescan
          ? AppBar(
              backgroundColor: Colors.transparent,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => context.go('/home'),
              ),
            )
          : null,
      body: Stack(
        children: [
          // Camera preview
          MobileScanner(
            controller: _scannerController,
            onDetect: _onDetect,
          ),

          // Overlay with instructions
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withAlpha(230),
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Scan cmux QR Code',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Open cmux Settings on your Mac and scan the QR code '
                    'to pair this device.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withAlpha(180),
                      fontSize: 14,
                    ),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFCF6679),
                        fontSize: 14,
                      ),
                    ),
                  ],
                  if (_processing) ...[
                    const SizedBox(height: 16),
                    const CircularProgressIndicator(
                      color: Color(0xFF00C853),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
