/// Voice recorder button for the modifier bar tools grid.
///
/// Renders as a 36px circular mic button with visual states driven by the
/// voice subsystem's [VoiceStatus]. Supports tap-to-toggle and hold-to-record
/// interaction modes, with haptic feedback on start/stop transitions.
///
/// Visual states:
///   - idle: outline mic icon, neutral background
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

/// A 36px circular mic button that controls voice recording.
///
/// Inputs:
///   Reads [voiceProvider] for current status and [connectionManagerProvider]
///   for sending RPC commands to the Mac.
///
/// Interaction:
///   - Tap (< 250ms press): toggles recording in tap-to-toggle mode.
///   - Long press (>= 250ms): starts hold-to-record; release stops recording.
class VoiceButton extends ConsumerStatefulWidget {
  const VoiceButton({super.key});

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
    final c = AppColors.of(context);
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

/// The 36x36px visual representation of the voice button.
///
/// Renders different icon/background/decoration combinations based on the
/// current [VoiceStatus], with a pulsing red ring during recording.
class _ButtonVisual extends StatelessWidget {
  final VoiceStatus status;
  final AnimationController pulseController;

  const _ButtonVisual({
    required this.status,
    required this.pulseController,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return AnimatedBuilder(
      animation: pulseController,
      builder: (context, _) {
        final bgColor = switch (status) {
          VoiceStatus.idle => c.keyGroupResting,
          VoiceStatus.recording => c.voiceRecordingBg,
          VoiceStatus.processing => c.voiceSetupAmber.withAlpha(40),
          VoiceStatus.setupRequired => c.keyGroupResting,
        };

        // Pulsing red ring shadow during recording.
        final boxShadows = status == VoiceStatus.recording
            ? [
                BoxShadow(
                  color: c.voiceRecordingRed
                      .withAlpha((80 + (pulseController.value * 80)).round()),
                  blurRadius: 8 + (pulseController.value * 6),
                  spreadRadius: pulseController.value * 2,
                ),
              ]
            : <BoxShadow>[];

        return SizedBox(
          width: 36,
          height: 36,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Button background circle.
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: bgColor,
                  boxShadow: boxShadows,
                ),
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

  /// Builds the center content: mic icon or circular progress indicator.
  Widget _buildContent(AppColorScheme c) {
    if (status == VoiceStatus.processing) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: c.voiceSetupAmber,
        ),
      );
    }

    final iconData = status == VoiceStatus.recording
        ? Icons.mic_rounded
        : Icons.mic_none_rounded;

    final iconColor = status == VoiceStatus.recording
        ? c.voiceRecordingRed
        : c.keyGroupText;

    return Icon(iconData, size: 16, color: iconColor);
  }
}
