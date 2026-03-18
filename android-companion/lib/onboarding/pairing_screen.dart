/// QR code pairing screen with branded dark styling.
///
/// Full-screen camera view with rounded viewfinder frame and
/// accentBlue corner markers. On successful scan, plays a brief
/// success animation before navigating to the terminal screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/colors.dart';
import '../app/providers.dart';

class PairingScreen extends ConsumerStatefulWidget {
  /// Whether this is an intentional re-scan from the terminal screen.
  final bool rescan;

  const PairingScreen({super.key, this.rescan = false});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _processing = false;
  bool _success = false;
  String? _errorMessage;

  late final AnimationController _successAnimController;
  late final Animation<double> _successScale;

  @override
  void initState() {
    super.initState();
    _successAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _successScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _successAnimController, curve: Curves.elasticOut),
    );
  }

  @override
  void dispose() {
    _successAnimController.dispose();
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

      final manager = ref.read(connectionManagerProvider);
      if (widget.rescan) {
        manager.disconnect();
      }
      manager.setCredentials(
        host: credentials.host,
        port: credentials.port,
        token: credentials.token,
      );

      // Show success animation, then navigate.
      setState(() => _success = true);
      _successAnimController.forward();

      await Future<void>.delayed(const Duration(milliseconds: 800));

      if (mounted) {
        context.go('/terminal');
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: Stack(
        children: [
          // Camera preview
          MobileScanner(
            controller: _scannerController,
            onDetect: _onDetect,
          ),

          // Dark overlay with viewfinder cutout
          _buildOverlay(context),

          // Back button (rescan mode)
          if (widget.rescan)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
                onPressed: () => context.go('/terminal'),
              ),
            ),

          // Success overlay
          if (_success)
            Container(
              color: AppColors.bgPrimary.withAlpha(230),
              child: Center(
                child: ScaleTransition(
                  scale: _successScale,
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withAlpha(30),
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.accentGreen, width: 2),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 40,
                      color: AppColors.accentGreen,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final viewfinderSize = screenWidth * 0.7;

    return Positioned.fill(
      child: Column(
        children: [
          // Top section: logo / branding
          Expanded(
            flex: 3,
            child: Container(
              color: AppColors.bgPrimary.withAlpha(180),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // cmux wordmark
                    Text(
                      'cmux',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        letterSpacing: -1,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Companion',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: AppColors.textSecondary,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Viewfinder row
          SizedBox(
            height: viewfinderSize,
            child: Row(
              children: [
                // Left dark bar
                Expanded(child: Container(color: AppColors.bgPrimary.withAlpha(180))),

                // Viewfinder frame with corner markers
                SizedBox(
                  width: viewfinderSize,
                  child: CustomPaint(
                    painter: _ViewfinderPainter(),
                  ),
                ),

                // Right dark bar
                Expanded(child: Container(color: AppColors.bgPrimary.withAlpha(180))),
              ],
            ),
          ),

          // Bottom section: instructions
          Expanded(
            flex: 4,
            child: Container(
              color: AppColors.bgPrimary.withAlpha(180),
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Scan cmux QR Code',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Open cmux Settings on your Mac and scan\nthe pairing QR code to connect.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),

                  // Error banner
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.accentRed.withAlpha(20),
                        borderRadius: BorderRadius.circular(AppColors.radiusSm),
                        border: Border.all(
                          color: AppColors.accentRed.withAlpha(60),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 16, color: AppColors.accentRed),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: AppColors.accentRed,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Processing spinner
                  if (_processing && !_success) ...[
                    const SizedBox(height: 20),
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: AppColors.accentBlue,
                        strokeWidth: 2,
                      ),
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

/// Paints viewfinder corner markers (blue L-shaped corners).
class _ViewfinderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.accentBlue
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const cornerLen = 24.0;
    const radius = 12.0;

    // Top-left corner
    canvas.drawPath(
      Path()
        ..moveTo(0, cornerLen)
        ..lineTo(0, radius)
        ..arcToPoint(Offset(radius, 0), radius: const Radius.circular(radius))
        ..lineTo(cornerLen, 0),
      paint,
    );

    // Top-right corner
    canvas.drawPath(
      Path()
        ..moveTo(size.width - cornerLen, 0)
        ..lineTo(size.width - radius, 0)
        ..arcToPoint(Offset(size.width, radius), radius: const Radius.circular(radius))
        ..lineTo(size.width, cornerLen),
      paint,
    );

    // Bottom-left corner
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height - cornerLen)
        ..lineTo(0, size.height - radius)
        ..arcToPoint(Offset(radius, size.height), radius: const Radius.circular(radius))
        ..lineTo(cornerLen, size.height),
      paint,
    );

    // Bottom-right corner
    canvas.drawPath(
      Path()
        ..moveTo(size.width - cornerLen, size.height)
        ..lineTo(size.width - radius, size.height)
        ..arcToPoint(Offset(size.width, size.height - radius), radius: const Radius.circular(radius))
        ..lineTo(size.width, size.height - cornerLen),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
