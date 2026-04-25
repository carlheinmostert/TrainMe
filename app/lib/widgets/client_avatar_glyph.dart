import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/client.dart';
import '../services/api_client.dart';
import '../services/path_resolver.dart';
import '../theme.dart';

/// Wave 30 — circular avatar glyph rendered next to the client name on
/// the client detail view (and reused anywhere we want to show the
/// avatar OR the initials fallback).
///
/// Resolution order:
///   1. Local file at `{Documents}/avatars/{clientId}.png` if it exists
///      — instant, offline-safe. Written by the capture flow.
///   2. Signed URL from the private `raw-archive` bucket via
///      `sign_storage_url`. Used when the local file is missing (a
///      different device captured the avatar; the cloud is the only
///      source of truth).
///   3. Initials monogram (first letter of the client name on a
///      coral-tinted disc) — same shape PracticeChip / _ClientCard use.
///
/// Tap fires [onTap] (the parent opens the capture flow or the consent
/// sheet depending on `client.avatarAllowed`).
class ClientAvatarGlyph extends StatefulWidget {
  /// Client whose avatar we render. Reads `avatarPath` + `name`.
  final PracticeClient client;

  /// Visual diameter of the circle. Default 40dp matches the
  /// `_ClientCard` person-badge so the two surfaces feel cohesive.
  final double diameter;

  /// Tap handler. Null = non-interactive disc.
  final VoidCallback? onTap;

  const ClientAvatarGlyph({
    super.key,
    required this.client,
    this.diameter = 40,
    this.onTap,
  });

  @override
  State<ClientAvatarGlyph> createState() => _ClientAvatarGlyphState();
}

class _ClientAvatarGlyphState extends State<ClientAvatarGlyph> {
  String? _signedUrl;
  String? _signedForPath;
  bool _signing = false;

  @override
  void didUpdateWidget(covariant ClientAvatarGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newPath = widget.client.avatarPath;
    if (newPath != oldWidget.client.avatarPath) {
      // Path changed — drop any cached signed URL so the next render
      // re-signs.
      setState(() {
        _signedUrl = null;
        _signedForPath = null;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Resolution
  // ---------------------------------------------------------------------------

  /// Returns the absolute path of the local PNG when one exists for this
  /// client, else null.
  String? _localFilePath() {
    try {
      final docs = PathResolver.docsDir;
      final candidate = p.join(docs, 'avatars', '${widget.client.id}.png');
      return File(candidate).existsSync() ? candidate : null;
    } catch (_) {
      return null;
    }
  }

  /// Lazily fetch a signed URL for the cloud-side avatar. Cached for the
  /// lifetime of this widget (an hour-ish from the RPC); a new path
  /// reset clears the cache via [didUpdateWidget].
  Future<void> _ensureSigned() async {
    final path = widget.client.avatarPath;
    if (path == null || path.isEmpty) return;
    if (_signedForPath == path && _signedUrl != null) return;
    if (_signing) return;
    setState(() => _signing = true);
    final url = await ApiClient.instance.signClientAvatarUrl(avatarPath: path);
    if (!mounted) return;
    setState(() {
      _signing = false;
      _signedForPath = path;
      _signedUrl = url;
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final hasPath =
        widget.client.avatarPath != null && widget.client.avatarPath!.isNotEmpty;
    final localPath = hasPath ? _localFilePath() : null;

    Widget content;
    if (localPath != null) {
      content = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildInitials(),
      );
    } else if (hasPath) {
      // Need a signed URL. Kick off the lazy fetch.
      // ignore: discarded_futures
      _ensureSigned();
      if (_signedUrl != null) {
        content = Image.network(
          _signedUrl!,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _buildInitials(),
        );
      } else {
        // Pending fetch — render the initials so the disc is never blank.
        content = _buildInitials();
      }
    } else {
      content = _buildInitials();
    }

    final disc = SizedBox(
      width: widget.diameter,
      height: widget.diameter,
      child: ClipOval(child: content),
    );

    if (widget.onTap == null) return disc;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.onTap,
        child: disc,
      ),
    );
  }

  Widget _buildInitials() {
    return Container(
      width: widget.diameter,
      height: widget.diameter,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        _initialsFor(widget.client.name),
        style: TextStyle(
          fontFamily: 'Montserrat',
          fontSize: widget.diameter * 0.4,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
          height: 1.0,
          letterSpacing: -0.3,
        ),
      ),
    );
  }

  /// Up to two initials from the name. Empty name → person glyph.
  /// Mirrors how PracticeChip computes its short label so the two
  /// circular surfaces feel consistent.
  static String _initialsFor(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '·';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    final first = parts.first.substring(0, 1);
    final last = parts.last.substring(0, 1);
    return (first + last).toUpperCase();
  }
}
