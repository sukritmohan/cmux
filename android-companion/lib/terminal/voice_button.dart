/// Placeholder voice recorder button for the modifier bar.
///
/// Renders as a circular mic icon that matches the modifier bar's visual style.
/// The button is non-functional — it exists only as a visual placeholder until
/// the voice recorder feature is designed and implemented in a future spec.
///
/// Color tokens are sourced from [AppColors.of(context)] so the button adapts
/// to both dark and light themes automatically.
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';

/// A 36px circular mic icon button that renders in the modifier bar.
///
/// Tapping does nothing. The button signals "coming soon" via its semantics
/// label so screen readers can communicate its intent to assistive technology.
class VoiceButton extends StatelessWidget {
  const VoiceButton({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Semantics(
      label: 'Voice recorder, coming soon',
      button: true,
      child: GestureDetector(
        // No-op: button is a placeholder, interaction is intentionally disabled.
        onTap: () {},
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.keyGroupResting,
          ),
          child: Center(
            child: Icon(
              Icons.mic_none_rounded,
              size: 16,
              color: c.keyGroupText,
            ),
          ),
        ),
      ),
    );
  }
}
