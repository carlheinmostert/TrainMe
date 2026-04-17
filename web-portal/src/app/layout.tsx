import type { Metadata } from 'next';
import './globals.css';

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
      <body className="min-h-screen bg-surface-bg text-ink">{children}</body>
    </html>
  );
}
