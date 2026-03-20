/// Horizontal scrollable strip of transcription chips shown above the modifier bar.
///
/// Displays voice transcription segments as compact chips with text, commit
/// progress, and dismiss controls. Slides up when the voice subsystem is
/// recording, processing, or has active chips. Includes a live waveform
/// visualizer and recording timer on the left.
///
/// Usage:
///   VoiceStrip(
///     state: voiceState,
///     onDismiss: (segmentId) => ref.read(voiceProvider.notifier).dismissChip(segmentId),
///   )
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';
import 'voice_protocol.dart';

/// A horizontal row of transcription chips that slides in above the modifier
/// bar when voice recording is active or chips are pending.
class VoiceStrip extends StatelessWidget {
  /// Current voice subsystem state.
  final VoiceState state;

  /// Called when the user dismisses a transcription chip (swipe or X button).
  final ValueChanged<int> onDismiss;

  const VoiceStrip({
    super.key,
    required this.state,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final isVisible = state.isStripVisible;

    return AnimatedSlide(
      offset: isVisible ? Offset.zero : const Offset(0, 1),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: isVisible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: _StripBody(state: state, onDismiss: onDismiss),
      ),
    );
  }
}

/// The visual container and content of the voice strip.
///
/// Separated from [VoiceStrip] so the animation wrapper stays lean.
/// Layout: [waveform 44x36] [timer] [chip scroll area]
class _StripBody extends StatelessWidget {
  final VoiceState state;
  final ValueChanged<int> onDismiss;

  const _StripBody({required this.state, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isRecording = state.status == VoiceStatus.recording;

    return Container(
      height: 52,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      decoration: BoxDecoration(
        color: c.voiceStripBg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(14),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              // Waveform visualizer — always visible when strip is shown.
              _WaveformVisualizer(isRecording: isRecording),

              // Recording timer — shown only while actively recording.
              if (isRecording && state.recordingDuration != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 8),
                  child: _RecordingTimer(duration: state.recordingDuration!),
                ),

              if (!isRecording)
                const SizedBox(width: 8),

              // Scrollable chip list fills remaining space.
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: state.chips.length,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final chip = state.chips[index];
                    return _TranscriptionChipWidget(
                      chip: chip,
                      onDismiss: () => onDismiss(chip.segmentId),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Waveform Visualizer
// ---------------------------------------------------------------------------

/// Animated 7-bar audio waveform displayed at the left of the voice strip.
///
/// When [isRecording] is true, bars animate with staggered sine-like height
/// changes. When stopped, bars shrink to a 4px resting height at 30% opacity.
class _WaveformVisualizer extends StatefulWidget {
  final bool isRecording;

  const _WaveformVisualizer({required this.isRecording});

  @override
  State<_WaveformVisualizer> createState() => _WaveformVisualizerState();
}

class _WaveformVisualizerState extends State<_WaveformVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Phase offsets for each of the 7 bars to create a staggered wave effect.
  static const _phaseOffsets = [0.0, 0.8, 1.6, 2.4, 3.2, 4.0, 4.8];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.isRecording) _controller.repeat();
  }

  @override
  void didUpdateWidget(_WaveformVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isRecording && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return SizedBox(
      width: 44,
      height: 36,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(7, (i) {
              final double barHeight;
              final double opacity;

              if (widget.isRecording) {
                // Sine wave with phase offset per bar, range [6, 28] px.
                final phase = _phaseOffsets[i];
                final value = math.sin(
                  (_controller.value * 2 * math.pi) + phase,
                );
                // Map [-1, 1] → [6, 28].
                barHeight = 6.0 + ((value + 1.0) / 2.0) * 22.0;
                opacity = 1.0;
              } else {
                barHeight = 4.0;
                opacity = 0.3;
              }

              return Padding(
                padding: EdgeInsets.only(left: i > 0 ? 2 : 0),
                child: AnimatedOpacity(
                  opacity: opacity,
                  duration: const Duration(milliseconds: 300),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 3,
                    height: barHeight,
                    decoration: BoxDecoration(
                      color: c.voiceRecordingRed,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Recording Timer
// ---------------------------------------------------------------------------

/// Shows the current recording duration in `m:ss` format.
class _RecordingTimer extends StatelessWidget {
  final Duration duration;

  const _RecordingTimer({required this.duration});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    final text = '$minutes:${seconds.toString().padLeft(2, '0')}';

    return Text(
      text,
      style: TextStyle(
        fontFamily: 'JetBrains Mono',
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: c.voiceTimerText,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Transcription Chip
// ---------------------------------------------------------------------------

/// A single transcription chip with text, dismiss control, trigger indicator,
/// and auto-commit progress bar.
///
/// - Pending: standard appearance, swipeable or X-dismissable.
/// - Committing: green-tinted border, 2px progress bar filling at bottom.
/// - Committed: reduced opacity and scale, non-interactive.
/// - Dismissed: removed from the list by the notifier (not rendered).
class _TranscriptionChipWidget extends StatelessWidget {
  final TranscriptionChip chip;
  final VoidCallback onDismiss;

  const _TranscriptionChipWidget({
    required this.chip,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    // Dismissed chips should not be rendered, but guard defensively.
    if (chip.status == ChipStatus.dismissed) return const SizedBox.shrink();

    final isCommitted = chip.status == ChipStatus.committed;
    final isCommitting = chip.status == ChipStatus.committing;

    // Committed chips are non-interactive: reduced opacity and slightly scaled.
    Widget chipWidget = _ChipContent(
      chip: chip,
      isCommitting: isCommitting,
      isCommitted: isCommitted,
      onDismiss: onDismiss,
    );

    if (isCommitted) {
      chipWidget = AnimatedOpacity(
        opacity: 0.4,
        duration: const Duration(milliseconds: 300),
        child: AnimatedScale(
          scale: 0.95,
          duration: const Duration(milliseconds: 300),
          child: chipWidget,
        ),
      );
    }

    // Pending and committing chips can be swiped to dismiss.
    if (!isCommitted) {
      chipWidget = Dismissible(
        key: ValueKey(chip.segmentId),
        direction: DismissDirection.startToEnd,
        onDismissed: (_) {
          HapticFeedback.lightImpact();
          onDismiss();
        },
        child: chipWidget,
      );
    }

    return chipWidget;
  }
}

/// Inner content of a transcription chip.
///
/// Renders the chip container with text, optional trigger indicator,
/// dismiss button, and commit progress bar.
class _ChipContent extends StatelessWidget {
  final TranscriptionChip chip;
  final bool isCommitting;
  final bool isCommitted;
  final VoidCallback onDismiss;

  const _ChipContent({
    required this.chip,
    required this.isCommitting,
    required this.isCommitted,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    final borderColor = isCommitting ? c.voiceCommitBorder : c.voiceChipBorder;
    final bgColor = isCommitting
        ? Color.alphaBlend(
            c.voiceCommitGreen.withAlpha(20),
            c.voiceChipBg,
          )
        : c.voiceChipBg;

    return Container(
      constraints: const BoxConstraints(maxWidth: 200),
      height: 36,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Stack(
        children: [
          // Main chip content: text + trigger indicator + dismiss button.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Trigger word indicator (return symbol in accent color).
                if (chip.hasTrigger)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      '\u23CE', // ⏎ return symbol
                      style: TextStyle(
                        fontSize: 12,
                        color: c.accent,
                      ),
                    ),
                  ),

                // Chip text.
                Flexible(
                  child: Text(
                    chip.text,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: c.textPrimary,
                    ),
                  ),
                ),

                // Dismiss button — hidden when committed.
                if (!isCommitted)
                  _RemoveButton(onTap: onDismiss),
              ],
            ),
          ),

          // Commit progress bar at the bottom of the chip.
          if (isCommitting)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _CommitProgressBar(),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Commit Progress Bar
// ---------------------------------------------------------------------------

/// 2px-tall green progress bar that fills from 0% to 100% over
/// [kChipAutoCommitDelay] when a chip enters the committing state.
class _CommitProgressBar extends StatefulWidget {
  @override
  State<_CommitProgressBar> createState() => _CommitProgressBarState();
}

class _CommitProgressBarState extends State<_CommitProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kChipAutoCommitDelay,
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: _controller.value,
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              color: c.voiceCommitGreen,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(2),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Remove Button
// ---------------------------------------------------------------------------

/// 16px close icon with tap handling and scale animation.
///
/// Identical to the attachment strip's remove button for visual consistency.
class _RemoveButton extends StatefulWidget {
  final VoidCallback onTap;

  const _RemoveButton({required this.onTap});

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 80),
        // Pad the hit target to at least 24px for accessibility.
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.close_rounded,
            size: 16,
            color: c.textMuted,
          ),
        ),
      ),
    );
  }
}
