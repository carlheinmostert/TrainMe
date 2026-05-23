import Link from 'next/link';
import type { Metadata } from 'next';
import { BrandHeader } from '@/components/BrandHeader';

export const metadata: Metadata = {
  title: 'Safe Mode — homefit.studio',
  description:
    'How homefit.studio Safe Mode protects identity in shared spaces — for subjects, bystanders, and the practitioners who film.',
};

// Bump alongside any material wording change. Mirrors the privacy /
// terms page convention so a reviewer scanning the top of the page
// sees the same date in the metadata and in the body.
const LAST_UPDATED = '2026-05-23';
const VERSION = '0.1-draft';

/**
 * `/safe-mode` — public transparency page for Safe Mode.
 *
 * Three-perspective explainer (subject / bystander / practitioner) of
 * how Safe Mode obscures identifying features in capture environments
 * shared with strangers (gyms, group sessions). Linked from the
 * premises-poster QR overlay so a curious gym member can scan the
 * poster, follow the URL on it, and land here.
 *
 * Source of truth for what Safe Mode does:
 *   docs/specs/2026-05-23-safe-mode-face-rec.md
 *
 * Static page. No client component, no analytics, no interactivity
 * past the header chrome — anyone can land here from a poster or a
 * link in an email without being asked for an account.
 *
 * Marked DRAFT in the page header: the legal / POPIA wording will be
 * polished by Carl's lawyer after the technical wording is correct.
 */
export default function SafeModePage() {
  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader />
      <div className="mx-auto w-full max-w-3xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link href="/" className="hover:text-brand">
            ← Home
          </Link>
        </nav>

        <div className="flex flex-wrap items-baseline gap-3">
          <h1 className="font-heading text-3xl font-bold sm:text-4xl">
            Safe Mode
          </h1>
          <span className="inline-flex items-center rounded-full border border-warning/50 bg-warning/10 px-3 py-1 text-xs font-medium uppercase tracking-wide text-warning">
            Draft — pending legal review
          </span>
        </div>
        <p className="mt-3 text-sm text-ink-muted">
          Last updated: <span className="text-ink">{LAST_UPDATED}</span>
          <span className="mx-2 text-ink-dim">·</span>
          Version <span className="text-ink font-mono">{VERSION}</span>
        </p>

        <p className="mt-6 text-base leading-relaxed text-ink">
          When a practitioner records an exercise demo in a shared space
          &mdash; a gym, a clinic waiting room, a park &mdash; the camera
          can catch people who never agreed to be on film. Safe Mode is
          the bit of the app that handles that. It runs on the
          practitioner&rsquo;s phone, on-device, and blurs every face
          that isn&rsquo;t the client being recorded. Below is what that
          means depending on who you are.
        </p>

        <div className="mt-10 space-y-12 text-base leading-relaxed text-ink">
          {/* Subject perspective ------------------------------------- */}
          <section>
            <h2 className="font-heading text-2xl font-semibold text-ink">
              If you&rsquo;re the subject
            </h2>
            <p className="mt-1 text-sm uppercase tracking-wide text-ink-muted">
              The client being filmed.
            </p>
            <div className="mt-4 space-y-4">
              <p>
                Your practitioner takes a regular photo of you once
                &mdash; the avatar that already represents you in their
                app. Safe Mode derives a numerical fingerprint of your
                face from that single photo and stores it only on your
                practitioner&rsquo;s phone and their practice&rsquo;s
                private database. That fingerprint never leaves their
                practice. It is not shared with us, not shared with
                other practices, and not used for analytics.
              </p>
              <p>
                From then on, whenever your practitioner records inside
                a Safe Mode area, the app recognises your face in the
                frame and keeps you sharp. Everyone else in shot &mdash;
                whether their face is visible or not &mdash; is blurred.
                The scenery around you stays unblurred so the video
                still looks like a real demo.
              </p>
              <p>
                The fingerprint is a list of 128 numbers. It cannot be
                turned back into a picture of your face. If you stop
                being a client, your practitioner can clear it from
                their app and it disappears from the database on next
                sync.
              </p>
            </div>
          </section>

          {/* Bystander perspective ----------------------------------- */}
          <section>
            <h2 className="font-heading text-2xl font-semibold text-ink">
              If you&rsquo;re a bystander
            </h2>
            <p className="mt-1 text-sm uppercase tracking-wide text-ink-muted">
              Someone who happens to be in the room.
            </p>
            <div className="mt-4 space-y-4">
              <p>
                Your face is blurred automatically. The practitioner
                doesn&rsquo;t have to tap anything, doesn&rsquo;t have
                to notice you, and doesn&rsquo;t see a version of the
                clip with your face on it. The blur is applied during
                capture, before the file is saved.
              </p>
              <p>
                We never store an image or a fingerprint of you. The
                app doesn&rsquo;t recognise you, doesn&rsquo;t identify
                you, and doesn&rsquo;t keep any data about you between
                captures. You walk past, your face is blurred, and the
                next frame works the same way from scratch.
              </p>
              <p>
                If you want to know who&rsquo;s recording at any
                specific premises that displays our poster, scan the
                QR code on the poster. You&rsquo;ll see the active
                session, who&rsquo;s running it, and a way to report a
                concern directly to the practice owner. The poster
                you&rsquo;re reading is part of the deal: practitioners
                using Safe Mode here have told us they will be
                identifiable to anyone who walks past.
              </p>
            </div>
          </section>

          {/* Practitioner perspective -------------------------------- */}
          <section>
            <h2 className="font-heading text-2xl font-semibold text-ink">
              If you&rsquo;re the practitioner
            </h2>
            <p className="mt-1 text-sm uppercase tracking-wide text-ink-muted">
              Or a solo gym-goer self-recording.
            </p>
            <div className="mt-4 space-y-4">
              <p>
                Setup is one tap per client. When you add a client&rsquo;s
                avatar &mdash; the same avatar you&rsquo;ve always added
                &mdash; the app generates the face fingerprint in the
                background. It takes a fraction of a second and you
                don&rsquo;t see it happen. From that point on, Safe Mode
                works for that client forever, with no further setup.
              </p>
              <p>
                On the premises side, you draw a polygon on a map
                covering the venue you film in. Inside that polygon,
                Safe Mode engages automatically the next time you open
                the camera. Outside it, the app behaves normally. You
                can mark a premises &ldquo;enforced&rdquo; to force
                Safe Mode on for any practitioner in your practice
                filming there.
              </p>
              <p>
                Once it&rsquo;s on, the workflow is unchanged. Point,
                shoot, save. The clip lands in the session with the
                client kept sharp and bystander faces blurred. The
                original un-blurred bytes never leave the device &mdash;
                only the safe variant uploads to the cloud, so the
                version your client sees and the version we store both
                respect the bystanders in the frame.
              </p>
              <p>
                If you&rsquo;re recording yourself solo &mdash; the
                tripod-in-the-gym case &mdash; Safe Mode handles you the
                same way it handles a client. Either your face is in
                shot and the app keeps you sharp; or your back is to
                the camera and the app blurs the visible faces of
                anyone else without touching the silhouettes. Scenery
                always stays sharp.
              </p>
            </div>
          </section>

          {/* What Safe Mode does not do ------------------------------ */}
          <section>
            <h2 className="font-heading text-2xl font-semibold text-ink">
              What Safe Mode does not do
            </h2>
            <div className="mt-4 space-y-4">
              <p>
                It doesn&rsquo;t recognise anyone you haven&rsquo;t
                explicitly added as a client of your practice. Random
                people in the background are blurred, not identified.
              </p>
              <p>
                It doesn&rsquo;t cross practices. A fingerprint stored
                by Practice A cannot be used by Practice B; the two
                practices live in separate database scopes that
                can&rsquo;t read each other.
              </p>
              <p>
                It doesn&rsquo;t send face data anywhere for
                processing. All face detection and recognition happens
                on the practitioner&rsquo;s iPhone using a model
                bundled with the app. No cloud round-trip per capture,
                no third-party face API, no biometric vendor.
              </p>
              <p>
                It doesn&rsquo;t cover video yet. Safe Mode v2, the
                version this page describes, is photos only. Video
                capture inside a Safe Mode area is suppressed in v2; a
                future v3 will extend the same blur logic to recorded
                video.
              </p>
            </div>
          </section>

          {/* Technical explainer ------------------------------------- */}
          <section>
            <h2 className="font-heading text-2xl font-semibold text-ink">
              How it works under the hood
            </h2>
            <p className="mt-1 text-sm uppercase tracking-wide text-ink-muted">
              For the curious.
            </p>
            <div className="mt-4 space-y-4">
              <p>
                Face detection is Apple&rsquo;s built-in Vision
                framework. Face recognition is MobileFaceNet, an
                MIT-licensed open-source model that runs through
                Apple&rsquo;s CoreML on the iPhone&rsquo;s neural
                engine. The model converts a 160-by-160 pixel crop of
                a face into a 128-dimensional vector &mdash; the
                fingerprint. Two photos of the same person produce
                vectors close together; two photos of different people
                produce vectors far apart. We compare them with cosine
                similarity at a 0.6 threshold.
              </p>
              <p>
                Person segmentation &mdash; the step that draws the
                silhouette of every human in the frame &mdash; also
                runs in Vision, on-device. The blur itself is a CoreImage
                Gaussian blur, masked to keep the subject silhouette and
                the background sharp while blurring everyone else.
              </p>
              <p>
                Storage: face fingerprints live as a 512-byte field on
                the client&rsquo;s row in the practice&rsquo;s database
                (a managed Postgres instance with row-level security
                scoped to the practice). They also cache on the
                practitioner&rsquo;s phone for offline use. They are
                marked with a model-version number so future model
                upgrades can detect and regenerate stale fingerprints.
              </p>
              <p>
                Algorithm changes are version-stamped on every capture,
                so when we improve Safe Mode in the future we can tell
                which clips were processed by the old version and
                offer to re-process them.
              </p>
            </div>
          </section>

          {/* Consent + control --------------------------------------- */}
          <section>
            <h2 className="font-heading text-2xl font-semibold text-ink">
              Consent and control
            </h2>
            <div className="mt-4 space-y-4">
              <p>
                Subject consent is explicit. The practitioner toggles
                &ldquo;Face recognition for Safe Mode&rdquo; on for a
                client before any fingerprint is generated. Toggling
                it off zeros the fingerprint on next sync; Safe Mode
                then refuses to capture that client until consent is
                granted again.
              </p>
              <p>
                Bystander consent is implied by the premises poster.
                The poster is the practice&rsquo;s public notice that
                recording is happening here and that the recording
                obscures non-clients. If you&rsquo;re a bystander and
                you don&rsquo;t want to be in the room at all, the
                poster gives you the information you need to leave or
                wait.
              </p>
              <p>
                Reports &mdash; concerns about a specific session or
                practitioner &mdash; go directly to the practice
                owner from the poster QR&rsquo;s &ldquo;Report&rdquo;
                button. We&rsquo;re a backstop, not the first
                responder.
              </p>
            </div>
          </section>
        </div>

        <footer className="mt-16 border-t border-surface-border pt-6 text-xs text-ink-muted">
          <p>
            See also our{' '}
            <Link href="/privacy" className="text-brand hover:underline">
              Privacy Policy
            </Link>{' '}
            and{' '}
            <Link href="/terms" className="text-brand hover:underline">
              Terms of Service
            </Link>
            .
          </p>
        </footer>
      </div>
    </main>
  );
}
