/// Voice recorder button for the modifier bar.
///
/// Default: 36px circle. Pass [width]/[height] for a pill shape (e.g., 44x76px
/// full-height pill). Visual states driven by [VoiceStatus]. Supports
/// tap-to-toggle and hold-to-record with haptic feedback.
///
/// Visual states:
///   - idle: custom gradient mic (amber→blue) with halo, convex pill
///   - recording: filled mic icon, pulsing red ring
///   - processing: spinning progress indicator, amber background
///   - setupRequired: outline mic icon with amber dot badge
///
/// Dependencies: reads [voiceProvider] and [connectionManagerProvider] via
/// Riverpod. Follows the same ConsumerStatefulWidget pattern as
/// [AttachmentButton].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/colors.dart';
import '../app/providers.dart';
import 'voice_protocol.dart';
import 'voice_service.dart';

/// Mic button that controls voice recording.
///
/// Default size is 36x36px (circle). Pass [width] and [height] to render as a
/// pill shape (e.g., 44x76px full-height pill in the modifier bar).
///
/// Inputs:
///   Reads [voiceProvider] for current status and [connectionManagerProvider]
///   for sending RPC commands to the Mac.
///
/// Interaction:
///   - Tap (< 250ms press): toggles recording in tap-to-toggle mode.
///   - Long press (>= 250ms): starts hold-to-record; release stops recording.
class VoiceButton extends ConsumerStatefulWidget {
  final double width;
  final double height;

  const VoiceButton({super.key, this.width = 36, this.height = 36});

  @override
  ConsumerState<VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends ConsumerState<VoiceButton>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;

  /// Timestamp when the user first pressed down, used to distinguish tap
  /// (< 250ms) from long press (>= 250ms).
  DateTime? _tapDownTime;

  /// Pulsing ring animation controller for the recording state.
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Interaction handlers
  // ---------------------------------------------------------------------------

  /// Records the press-down timestamp for tap/hold classification.
  void _onTapDown(TapDownDetails _) {
    _tapDownTime = DateTime.now();
    setState(() => _pressed = true);
  }

  /// On release, classify as tap (< 250ms) or hold release (>= 250ms).
  void _onTapUp(TapUpDetails _) {
    setState(() => _pressed = false);

    final downTime = _tapDownTime;
    _tapDownTime = null;
    if (downTime == null) return;

    final pressDuration = DateTime.now().difference(downTime);

    if (pressDuration < kTapMaxDuration) {
      _handleTap();
    } else {
      _handleHoldRelease();
    }
  }

  void _onTapCancel() {
    setState(() => _pressed = false);
    _tapDownTime = null;
  }

  /// Tap while idle: check readiness and start tap-toggle recording.
  /// Tap while recording: stop recording.
  void _handleTap() {
    final status = ref.read(voiceProvider).status;
    final manager = ref.read(connectionManagerProvider);
    final notifier = ref.read(voiceProvider.notifier);

    switch (status) {
      case VoiceStatus.idle:
        HapticFeedback.mediumImpact();
        notifier.startRecording(RecordingMode.tapToggle, manager);

      case VoiceStatus.recording:
        HapticFeedback.lightImpact();
        notifier.stopRecording(manager);

      case VoiceStatus.processing:
        // Ignore taps while processing — transcription is in flight.
        break;

      case VoiceStatus.setupRequired:
        HapticFeedback.lightImpact();
        // Setup is managed by the Mac desktop app automatically.
        // Show a toast to inform the user instead of triggering setup from phone.
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Voice setup in progress on your Mac'),
              duration: Duration(seconds: 3),
            ),
          );
        }
    }
  }

  /// Hold release: stop recording if we were in hold-to-record mode.
  void _handleHoldRelease() {
    final state = ref.read(voiceProvider);
    if (state.status != VoiceStatus.recording) return;
    if (state.recordingMode != RecordingMode.holdToRecord) return;

    HapticFeedback.lightImpact();
    final manager = ref.read(connectionManagerProvider);
    ref.read(voiceProvider.notifier).stopRecording(manager);
  }

  /// Long press: start hold-to-record mode immediately.
  void _onLongPressStart(LongPressStartDetails _) {
    final status = ref.read(voiceProvider).status;
    if (status != VoiceStatus.idle) return;

    HapticFeedback.mediumImpact();
    final manager = ref.read(connectionManagerProvider);
    ref.read(voiceProvider.notifier).startRecording(
      RecordingMode.holdToRecord,
      manager,
    );
  }

  /// Long press end: stop hold-to-record.
  void _onLongPressEnd(LongPressEndDetails _) {
    _handleHoldRelease();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final voiceState = ref.watch(voiceProvider);
    final status = voiceState.status;

    // Drive pulse animation based on recording state.
    if (status == VoiceStatus.recording && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (status != VoiceStatus.recording && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 0.0;
    }

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onLongPressStart: _onLongPressStart,
      onLongPressEnd: _onLongPressEnd,
      child: Semantics(
        label: _semanticsLabel(status),
        button: true,
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: _ButtonVisual(
            status: status,
            pulseController: _pulseController,
            width: widget.width,
            height: widget.height,
          ),
        ),
      ),
    );
  }

  /// Returns the accessibility label for the current voice status.
  String _semanticsLabel(VoiceStatus status) {
    return switch (status) {
      VoiceStatus.idle => 'Voice input',
      VoiceStatus.recording => 'Recording voice, tap to stop',
      VoiceStatus.processing => 'Processing voice input',
      VoiceStatus.setupRequired => 'Voice input, setup required',
    };
  }
}

// ---------------------------------------------------------------------------
// Button Visual
// ---------------------------------------------------------------------------

/// Visual representation of the voice button.
///
/// Renders different icon/background/decoration combinations based on the
/// current [VoiceStatus], with a pulsing red ring during recording.
/// Supports dynamic sizing for both circle (36x36) and pill (e.g., 44x76) shapes.
///
/// Idle state uses a custom-painted mic icon with warm-to-cool gradient capsule
/// fill and amber halo glow, inside a 3D convex raised pill with subtle
/// top highlight and drop shadow (3B-1 design).
class _ButtonVisual extends StatelessWidget {
  final VoiceStatus status;
  final AnimationController pulseController;
  final double width;
  final double height;

  const _ButtonVisual({
    required this.status,
    required this.pulseController,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return AnimatedBuilder(
      animation: pulseController,
      builder: (context, _) {
        // Use half the smaller dimension for pill/circle shape.
        final borderRadius = BorderRadius.circular(
          width < height ? width / 2 : height / 2,
        );

        // Idle state: 3B-1 convex raised pill with gradient + shadow.
        final isIdle = status == VoiceStatus.idle ||
            status == VoiceStatus.setupRequired;

        final decoration = isIdle
            ? BoxDecoration(
                borderRadius: borderRadius,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [c.micPillGradientTop, c.micPillGradientBot],
                ),
                boxShadow: [
                  BoxShadow(
                    color: c.micPillShadow,
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              )
            : BoxDecoration(
                borderRadius: borderRadius,
                color: switch (status) {
                  VoiceStatus.recording => c.voiceRecordingBg,
                  VoiceStatus.processing => c.voiceSetupAmber.withAlpha(40),
                  _ => c.keyGroupResting,
                },
                boxShadow: status == VoiceStatus.recording
                    ? [
                        BoxShadow(
                          color: c.voiceRecordingRed.withAlpha(
                            (80 + (pulseController.value * 80)).round(),
                          ),
                          blurRadius: 8 + (pulseController.value * 6),
                          spreadRadius: pulseController.value * 2,
                        ),
                      ]
                    : null,
              );

        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Button background (circle or pill).
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: width,
                height: height,
                decoration: decoration,
              ),

              // Icon or spinner.
              _buildContent(c),

              // Setup-required amber dot badge (top-right).
              if (status == VoiceStatus.setupRequired)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.voiceSetupAmber,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Builds the center content: custom gradient mic, recording icon, or spinner.
  /// Icon scales with button size: 20px for large buttons, 16px for default.
  Widget _buildContent(AppColorScheme c) {
    final isLarge = width > 36 || height > 36;
    final iconSize = isLarge ? 20.0 : 16.0;
    final spinnerSize = isLarge ? 20.0 : 16.0;

    if (status == VoiceStatus.processing) {
      return SizedBox(
        width: spinnerSize,
        height: spinnerSize,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: c.voiceSetupAmber,
        ),
      );
    }

    // Recording: keep the standard filled red mic icon.
    if (status == VoiceStatus.recording) {
      return Icon(Icons.mic_rounded, size: iconSize, color: c.voiceRecordingRed);
    }

    // Idle / setupRequired: custom painted mic with gradient + halo.
    return CustomPaint(
      size: Size(iconSize, iconSize),
      painter: _MicIconPainter(
        gradientWarm: c.micGradientWarm,
        gradientCool: c.micGradientCool,
        haloColor: c.micHaloColor,
        strokeColor: c.micStrokeColor,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Custom Mic Icon Painter
// ---------------------------------------------------------------------------

/// Paints a mic icon with warm-to-cool gradient capsule fill and amber halo.
///
/// The icon is drawn in a 24×24 coordinate space and scaled to [size].
/// Elements:
///   1. Amber halo glow behind the capsule (blurred paint)
///   2. Capsule with linear gradient fill (amber bottom → slate-blue top)
///   3. Cradle arc below the capsule
///   4. Vertical stem
///   5. Horizontal base line
class _MicIconPainter extends CustomPainter {
  final Color gradientWarm;
  final Color gradientCool;
  final Color haloColor;
  final Color strokeColor;

  _MicIconPainter({
    required this.gradientWarm,
    required this.gradientCool,
    required this.haloColor,
    required this.strokeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Scale from 24×24 coordinate space to actual size.
    final sx = size.width / 24;
    final sy = size.height / 24;
    canvas.save();
    canvas.scale(sx, sy);

    final strokeW = 1.5 / sx; // Keep stroke visually consistent.

    // 1. Amber halo glow behind the capsule.
    final haloRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(9, 2, 6, 12),
      const Radius.circular(3),
    );
    final haloPaint = Paint()
      ..color = haloColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawRRect(haloRect, haloPaint);

    // 2. Capsule with gradient fill.
    final capsuleRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(9, 2, 6, 12),
      const Radius.circular(3),
    );
    final gradientPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [gradientWarm, gradientCool],
      ).createShader(const Rect.fromLTWH(9, 2, 6, 12));
    canvas.drawRRect(capsuleRect, gradientPaint);

    // Shared stroke paint for cradle, stem, and base.
    final sPaint = Paint()
      ..color = strokeColor
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // 3. Cradle arc: from (5, 10) curving down to (19, 10).
    final cradlePath = Path()
      ..moveTo(5, 10)
      ..arcToPoint(
        const Offset(19, 10),
        radius: const Radius.circular(7),
        clockwise: false,
      );
    canvas.drawPath(cradlePath, sPaint);

    // 4. Stem line.
    canvas.drawLine(const Offset(12, 17), const Offset(12, 21), sPaint);

    // 5. Base line.
    canvas.drawLine(const Offset(9, 21), const Offset(15, 21), sPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MicIconPainter oldDelegate) =>
      gradientWarm != oldDelegate.gradientWarm ||
      gradientCool != oldDelegate.gradientCool ||
      haloColor != oldDelegate.haloColor ||
      strokeColor != oldDelegate.strokeColor;
}
