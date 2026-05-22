import type { Metadata } from 'next';
import { Inter, Montserrat } from 'next/font/google';
import './globals.css';
import { BuildInfo } from '@/components/BuildInfo';

const inter = Inter({
  subsets: ['latin'],
  weight: ['400', '500', '600', '700'],
  variable: '--font-inter',
  display: 'swap',
});

const montserrat = Montserrat({
  subsets: ['latin'],
  weight: ['600', '700', '800'],
  variable: '--font-montserrat',
  display: 'swap',
});

export const metadata: Metadata = {
  title: 'homefit.studio — Practice portal',
  description:
    'Manage your homefit.studio practice: credits, audit log, and practitioner invites.',
  icons: {
    icon: [{ url: '/favicon.ico' }],
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <body
        className={`${inter.variable} ${montserrat.variable} min-h-screen bg-surface-bg text-ink`}
      >
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
