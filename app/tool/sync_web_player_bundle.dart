// Wave 4 Phase 1 — unified player prototype.
//
// Copy the canonical `web-player/` bundle (source of truth for both
// session.homefit.studio AND the Flutter-embedded prototype) into
// `app/assets/web-player/` so the `LocalPlayerServer` can serve it
// out of `rootBundle`.
//
// Kept intentionally tiny — this is a pre-build shim, not a build
// system. Run from `app/`:
//
//     dart run tool/sync_web_player_bundle.dart
//
// The bundle is NOT generated at build time today; the copied files
// are committed to git so reviewers can see the exact bytes that ship
// in the iOS .app. If the web-player changes, re-run this script and
// commit the updated assets in the same PR as the source edit — keeps
// R-10 parity with the mobile surface.
//
// sw.js, vercel.json, serve.json, and middleware.js are deliberately
// excluded. The embedded surface has no service worker (see
// `web-player/app.js` SW-registration skip for `isLocalSurface()`) and
// the Vercel-only files are server-config artefacts.

// ignore_for_file: avoid_print

import 'dart:io';

const _filesToCopy = <String>[
  'index.html',
  'app.js',
  'api.js',
  'styles.css',
];

void main(List<String> args) {
  final appDir = Directory.current; // assumed to be `app/`
  final repoRoot = appDir.parent;
  final src = Directory('${repoRoot.path}/web-player');
  final dst = Directory('${appDir.path}/assets/web-player');

  if (!src.existsSync()) {
    stderr.writeln('source dir not found: ${src.path}');
    exit(1);
  }
  dst.createSync(recursive: true);

  for (final name in _filesToCopy) {
    final srcFile = File('${src.path}/$name');
    if (!srcFile.existsSync()) {
      stderr.writeln('source file missing: ${srcFile.path}');
      exit(1);
    }
    final dstFile = File('${dst.path}/$name');
    dstFile.writeAsBytesSync(srcFile.readAsBytesSync());
    print('copied ${srcFile.path} -> ${dstFile.path}');
  }
  print('web-player bundle synced (${_filesToCopy.length} files)');
}
