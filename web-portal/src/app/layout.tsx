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
    <html lang="en" className="dark">
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
          - `pb-12` (48px) reserves space at the bottom of every page so
            the fixed build-marker chip (bottom-2 right-3, ~22px tall)
            never paints over the bottom-most card on narrow viewports.
            min-h-screen still applies — content can grow past the
            viewport and the chip stays anchored to the visual bottom.
      */}
      <body className="min-h-screen overflow-x-hidden bg-surface-bg pb-12 text-ink">
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
