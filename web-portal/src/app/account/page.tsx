import Link from 'next/link';
import QRCode from 'qrcode';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { AccountPanel } from '@/components/AccountPanel';
import { PracticeNameField } from '@/components/PracticeNameField';
import { AppStoreBadge } from '@/components/AppStoreBadge';
import { APP_STORE_URL, APP_STORE_LABEL } from '@/lib/links';

type SearchParams = { practice?: string };

// App version. Kept as a constant + env override so CI can bake a real value
// later. TODO: wire to web-portal/package.json.version at build time.
const APP_VERSION =
  process.env.NEXT_PUBLIC_APP_VERSION ?? '0.1.0';

// Build SHA + branch. Vercel exposes these automatically to builds; the
// `NEXT_PUBLIC_GIT_*` mirrors come from `next.config.mjs` (the same source
// that feeds the fixed-corner <BuildInfo /> chip). Falls back to 'dev' /
// 'local' for local development. Rendered at 35% opacity (R-08 equivalent
// to the Flutter build-marker on the Pulse Mark footer).
const BUILD_SHA =
  process.env.NEXT_PUBLIC_GIT_SHA ??
  process.env.NEXT_PUBLIC_VERCEL_GIT_COMMIT_SHA?.slice(0, 7) ??
  process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 7) ??
  'dev';
const BUILD_BRANCH =
  process.env.NEXT_PUBLIC_GIT_BRANCH ??
  process.env.VERCEL_GIT_COMMIT_REF ??
  'local';

export default async function AccountPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/');

  const params = await searchParams;
  const practiceId = params.practice ?? '';

  // Resolve role so the header can surface the owner-only Members link
  // while the caller is on /account. No practice in the qs → default to
  // false (the Members link hides, matching the practitioner fallback).
  //
  // Also load every practice the caller belongs to + pick the one that
  // matches `?practice=`. This powers the Practice-name field below
  // (owner-gated rename). We fall back to the caller's first membership
  // when the qs is missing — consistent with the dashboard's default.
  const api = createPortalApi(supabase);
  const [role, practices] = await Promise.all([
    practiceId ? api.getCurrentUserRole(practiceId, user.id) : Promise.resolve(null),
    api.listMyPractices(),
  ]);
  const isOwner = role === 'owner';

  const activePracticeId =
    practiceId || practices[0]?.id || '';
  const activePractice =
    practices.find((p) => p.id === activePracticeId) ?? practices[0] ?? null;

  // Practitioners on the active practice can't rename it. Default to
  // false when there's no membership (edge case — user w/ no practices).
  const canRenamePractice = activePractice
    ? (practices.find((p) => p.id === activePractice.id)?.role === 'owner')
    : false;

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={practiceId}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-2xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={practiceId ? `/dashboard?practice=${practiceId}` : '/dashboard'}
            className="hover:text-brand"
          >
            ← Home
          </Link>
        </nav>

        <h1 className="font-heading text-3xl font-bold">Account</h1>
        <p className="mt-2 text-sm text-ink-muted">
          Signed in as{' '}
          <span className="text-ink">{user.email ?? 'unknown'}</span>.
        </p>

        {/*
          Practice name — sits ABOVE the password + sign-out panel so
          owners find it first when landing on Account. Practitioners
          see a read-only rendering with a one-liner explanation. Using
          the membership-resolved role (not a server-side 401) because
          the practice is implicit context, not a permission boundary.
        */}
        {activePractice && (
          <div className="mt-8">
            <PracticeNameField
              practiceId={activePractice.id}
              initialName={activePractice.name}
              canEdit={canRenamePractice}
            />
          </div>
        )}

        <AccountPanel email={user.email ?? ''} />

        {/* C-13: permanent home for the App Store install link.
            Renders regardless of whether the practice has published —
            covers the "I dismissed the loud dashboard banner but now
            I'm on a new device" case. The QR is generated at request
            time so the user can scan from a desktop browser. */}
        <AppsSection qrSvg={await generateAppStoreQr()} />

        <section
          className="mt-12 border-t border-surface-border pt-8"
          aria-labelledby="about-heading"
        >
          <h2
            id="about-heading"
            className="font-heading text-lg font-semibold"
          >
            About
          </h2>
          <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
            <dt className="text-ink-muted">App</dt>
            <dd className="text-ink">homefit.studio practice portal</dd>

            <dt className="text-ink-muted">Version</dt>
            <dd className="text-ink font-mono">{APP_VERSION}</dd>

            <dt className="text-ink-muted">Build</dt>
            <dd className="font-mono text-ink opacity-[0.35]">
              {BUILD_SHA} · {BUILD_BRANCH}
            </dd>
          </dl>
        </section>
      </div>
    </main>
  );
}

/**
 * Generate the App Store install QR code as inline SVG at request time.
 * Same configuration as the GetTheAppBanner component so both surfaces
 * scan to identical pixels. The QR encodes APP_STORE_URL — flip the
 * constant in `lib/links.ts` when the app ships through review.
 */
async function generateAppStoreQr(): Promise<string> {
  return QRCode.toString(APP_STORE_URL, {
    type: 'svg',
    errorCorrectionLevel: 'M',
    margin: 1,
    color: {
      dark: '#0F1117',
      light: '#FFFFFF',
    },
  });
}

/**
 * AppsSection — permanent "Get the iOS app" affordance on /account.
 * Mirrors the App Store badge + QR from the dashboard's
 * GetTheAppBanner so re-installs / new devices can always find the
 * link, even after the loud banner has auto-dismissed.
 */
function AppsSection({ qrSvg }: { qrSvg: string }) {
  return (
    <section
      className="mt-12 border-t border-surface-border pt-8"
      aria-labelledby="apps-heading"
    >
      <h2
        id="apps-heading"
        className="font-heading text-lg font-semibold"
      >
        Apps
      </h2>
      <p className="mt-2 text-sm text-ink-muted">
        Clients and Classes live in the iOS app — the portal manages
        your account, credits, and audit log. Get the app on a new
        device by tapping the badge or scanning the QR code.
      </p>
      <div className="mt-5 flex flex-wrap items-center gap-5">
        <AppStoreBadge href={APP_STORE_URL} label={APP_STORE_LABEL} />
        <div
          aria-label="QR code to install on iPhone"
          className="overflow-hidden rounded bg-white p-2"
        >
          <div
            className="h-[120px] w-[120px]"
            // QR is server-rendered SVG — safe to inline; encoded from
            // a constant URL we control.
            dangerouslySetInnerHTML={{ __html: qrSvg }}
          />
        </div>
      </div>
      <p className="mt-3 text-xs text-ink-dim">
        Android coming soon.
      </p>
    </section>
  );
}
