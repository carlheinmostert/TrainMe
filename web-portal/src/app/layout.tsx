import type { Metadata, Viewport } from 'next';
import './globals.css';
import { BuildInfo } from '@/components/BuildInfo';
import { TopProgressBar } from '@/components/TopProgressBar';

export const metadata: Metadata = {
  // Browser tab title intentionally omits "Dashboard" — the dashboard
  // IS the home page now (cosmetic pass 2026-05-22), and the lockup at
  // the top of every page already says "homefit.studio".
  title: 'homefit.studio',
  description:
    'Manage your homefit.studio practice: credits, audit log, and practitioner invites.',
  icons: {
    icon: [{ url: '/favicon.ico' }],
  },
};

// Viewport (iPhone-portrait fix, 2026-05-25):
//   - `viewportFit: 'cover'` is required for `env(safe-area-inset-*)`
//     to resolve to a non-zero value on iOS. Without this the header's
//     safe-area-inset top padding would no-op and the brand lockup
//     would still paint into the iOS status-bar zone.
//   - `width: 'device-width'` + `initialScale: 1` are the standard
//     mobile defaults; declared explicitly so Next.js doesn't fall
//     back to its older `width=device-width,initial-scale=1` string.
export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark overflow-x-hidden">
      <head>
        {/* Google Fonts — Montserrat (headings) + Inter (body). */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link
          rel="preconnect"
          href="https://fonts.gstatic.com"
          crossOrigin=""
        />
        <link
          href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Montserrat:wght@600;700;800&display=swap"
          rel="stylesheet"
        />
      </head>
      {/*
        Body chrome (iPhone-portrait fix, 2026-05-25):
          - `overflow-x-hidden` traps any accidental ~1-2px overflow from
            shadows / focus rings / decorative chrome so iPhone portrait
            doesn't surface a horizontal scrollbar. Every legitimate
            layout uses `max-w-*` + `mx-auto`, so this is purely a
            safety net.

        iPhone-portrait follow-up (2026-05-25):
          - The previous `pb-12` body padding is removed. It was meant to
            reserve space below the fixed build chip, but a fixed-layer
            chip floats over whatever paints at its pixel coordinates
            regardless of body padding (extending the flow only changes
            where the body ENDS, not where the chip sits). BuildInfo is
            now rendered as a normal in-flow block at narrow widths and
            only switches to `position: fixed` at `md+`, so the chip can
            never visually paint over the bottom-most card on iPhone
            portrait and the desktop chrome stays uncluttered.

        iPhone-portrait wave 3 follow-up (2026-05-25):
          - `overflow-x-hidden` was added to `<html>` above (defensive
            backstop). PR #495 trapped overflow on `<body>` only, but
            when a descendant grew wider than the viewport the document
            root (`<html>`) still scrolled horizontally on iOS Safari
            because `<body>`'s clipping doesn't propagate up to the
            initial containing block. The dashboard card inner-row + grid
            fixes in PR #503 remove the cause of overflow; this html-
            level clip is purely a backstop so a future regression can
            never resurface horizontal scrolling at the document level.
      */}
      <body className="min-h-screen overflow-x-hidden bg-surface-bg text-ink">
        <TopProgressBar />
        {children}
        {/* Discreet build-marker chip — git SHA + branch at 35% opacity
            in the fixed bottom-right corner. Mirrors the Flutter mobile
            pattern + the web-player footer chip. Render once at the
            layout root so every route inherits it. */}
        <BuildInfo />
      </body>
    </html>
  );
}
