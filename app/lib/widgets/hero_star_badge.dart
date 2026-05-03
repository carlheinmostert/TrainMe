import 'package:flutter/material.dart';

import '../theme.dart';

/// Small coral star badge anchored top-left of a media surface, signalling
/// "this is the Hero frame".
///
/// Used by both [MiniPreview] (Studio editor's live mini preview) and
/// [CaptureThumbnail] (camera peek box, ThumbnailPeek closed state).
/// Video exercises always show the badge — the thumbnail IS the Hero
/// (motion-peak default or practitioner-picked via the trim panel).
/// Photos and rest periods never show it.
///
/// The badge is just the glyph (no plate / backdrop) with a subtle 1px
/// black drop-shadow so the coral stays legible against light thumbnails.
/// Fixed 14px to read consistently across the small thumbnail surfaces;
/// the long-press 240px preview drops the badge via the surrounding
/// `showChrome` gate. `IgnorePointer` keeps taps falling through to the
/// host card.
///
/// Designed to live INSIDE a [Stack] — it's a [Positioned] widget.
class HeroStarBadge extends StatelessWidget {
  const HeroStarBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      top: 6,
      left: 6,
      child: IgnorePointer(
        child: Icon(
          Icons.star_rounded,
          size: 14,
          color: AppColors.primary,
          shadows: [
            Shadow(
              color: Colors.black54,
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
      ),
    );
  }
}
