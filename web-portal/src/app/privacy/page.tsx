import Link from 'next/link';
import type { Metadata } from 'next';
import { BrandHeader } from '@/components/BrandHeader';

export const metadata: Metadata = {
  title: 'Privacy Policy — homefit.studio',
  description:
    'How homefit.studio collects, uses, and protects personal information under POPIA.',
};

// Effective date — bumped whenever a material change is published. Keep
// this in lockstep with the "Last updated" line in section 1 below; a
// reviewer scanning the head of the page should see the same date in
// the metadata as in the body.
const LAST_UPDATED = '2026-04-28';
const VERSION = '0.1-draft';

/**
 * Privacy Policy — scaffold for legal review.
 *
 * Prose is pre-filled from facts we know about the system (sub-processors,
 * no analytics, retention windows, consent model, POPIA cross-border
 * basis). Sections that need a lawyer to confirm wording are marked
 * inline with `[BRACKETED PLACEHOLDER — lawyer to confirm]`. Carl will
 * hand this to a ZA lawyer for red-pen; their job is copy-edit, not
 * greenfield.
 *
 * Static page — no client component, no interactivity. The header is
 * rendered without `showSignOut` so the page is reachable without a
 * session (Apple reviewers, anonymous visitors from the App Store
 * listing or in-app legal links).
 */
export default function PrivacyPolicyPage() {
  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader />
      <div className="mx-auto w-full max-w-3xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link href="/" className="hover:text-brand">
            ← Home
          </Link>
        </nav>

        <h1 className="font-heading text-3xl font-bold sm:text-4xl">
          Privacy Policy
        </h1>
        <p className="mt-3 text-sm text-ink-muted">
          Last updated:{' '}
          <span className="text-ink">{LAST_UPDATED}</span>
          <span className="mx-2 text-ink-dim">·</span>
          Version <span className="text-ink font-mono">{VERSION}</span>
        </p>

        <div className="mt-4 rounded-md border border-warning/40 bg-warning/10 p-4 text-sm text-ink">
          <strong className="text-warning">Draft for legal review.</strong>{' '}
          This document is a scaffold pending sign-off from a South
          African attorney. Bracketed placeholders mark the sections that
          need a lawyer&rsquo;s wording before publication.
        </div>

        <article className="prose-policy mt-10 space-y-10 text-sm leading-relaxed text-ink">
          {/* 1. Effective date + version */}
          <Section heading="1. Effective date and how we notify changes">
            <P>
              This policy is effective from {LAST_UPDATED}. We may revise
              it as the service evolves. When we make a{' '}
              <em>material</em> change &mdash; one that broadens the
              purposes for which we use personal information, adds a
              sub-processor in a new jurisdiction, or weakens any data
              subject right &mdash; we will give you reasonable advance
              notice through both the in-app banner on the homefit.studio
              iOS app and a sign-in banner on{' '}
              <code>manage.homefit.studio</code>. Non-material edits
              (typo fixes, contact-detail updates) take effect on
              publication.
            </P>
            <P>
              Every revision bumps the version number above. The full
              change log lives in our public repository alongside the
              source for this page.
            </P>
          </Section>

          {/* 2. Who we are */}
          <Section heading="2. Who we are">
            <P>
              <strong>homefit.studio</strong> (&ldquo;homefit.studio&rdquo;,
              &ldquo;we&rdquo;, &ldquo;our&rdquo;) is a sole
              proprietorship trading in the Republic of South Africa. The
              responsible party under section 1 of the Protection of
              Personal Information Act, 4 of 2013 (POPIA) is{' '}
              <strong>Carl Mostert, trading as homefit.studio</strong>.
              No company has been registered for this trading name as of
              the effective date.
            </P>
            <P>
              You can reach us at{' '}
              <a
                href="mailto:privacy@homefit.studio"
                className="text-brand hover:underline"
              >
                privacy@homefit.studio
              </a>
              . Postal address:{' '}
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer / Carl to confirm
                physical address for service of POPIA notices]
              </em>
              .
            </P>
          </Section>

          {/* 3. Information Officer (POPIA s.55) */}
          <Section heading="3. Information Officer (POPIA s.55)">
            <P>
              The Information Officer is Carl Mostert. POPIA section 55
              defines the Information Officer&rsquo;s duties: encouraging
              compliance with the Act, dealing with requests, and
              cooperating with the Information Regulator. As a sole
              proprietor, Carl performs this role personally and can be
              reached at{' '}
              <a
                href="mailto:privacy@homefit.studio"
                className="text-brand hover:underline"
              >
                privacy@homefit.studio
              </a>
              .
            </P>
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm whether
                registration with the Information Regulator is required
                given the scale of processing and to advise on the form
                / timing of registration if so.]
              </em>
            </P>
          </Section>

          {/* 4. Scope */}
          <Section heading="4. Scope of this policy">
            <P>This policy applies to three surfaces:</P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                The <strong>homefit.studio iOS app</strong> used by
                practitioners (biokineticists, physiotherapists,
                occupational therapists, fitness trainers).
              </li>
              <li>
                The <strong>practitioner web portal</strong> at{' '}
                <code>manage.homefit.studio</code> where practice owners
                buy credits, view audit history, and invite practitioners.
              </li>
              <li>
                The <strong>client web player</strong> at{' '}
                <code>session.homefit.studio</code> where the
                practitioner&rsquo;s clients view their plan. The client
                web player is anonymous and does not require an account.
              </li>
            </ul>
            <P className="mt-4">
              The policy distinguishes two roles. A{' '}
              <strong>practitioner</strong> is a user of the homefit.studio
              service, has an account, and is our direct data subject for
              their own personal information. A <strong>client</strong>{' '}
              is a person whose exercise demonstration is captured by a
              practitioner. For client data, the practitioner is the
              responsible party (controller) and we act as an operator
              (processor) on their behalf, except to the limited extent
              that we use de-identified telemetry of the platform itself
              (see section 7).
            </P>
          </Section>

          {/* 5. What we collect */}
          <Section heading="5. What information we collect">
            <h3 className="mt-4 font-heading text-base font-semibold text-ink">
              (a) Practitioner data
            </h3>
            <ul className="mt-2 list-disc space-y-1 pl-6 text-ink">
              <li>Email address (for sign-in).</li>
              <li>Optional password hash (we never store the password itself).</li>
              <li>Practice name and your role within it (owner or practitioner).</li>
              <li>
                Credit purchase history including PayFast payment
                identifiers and amounts (see section 18).
              </li>
              <li>
                Audit metadata for plans you publish: plan id, version
                number, timestamp, exercise count, credit cost.
              </li>
              <li>
                If you opt in, your referral code and the referees who
                claim it, plus the rebate credits earned.
              </li>
            </ul>
            <P className="text-ink-muted">
              We do <strong>not</strong> collect device identifiers,
              advertising IDs, or any cross-app identifiers.
            </P>

            <h3 className="mt-6 font-heading text-base font-semibold text-ink">
              (b) Client data entered by the practitioner
            </h3>
            <ul className="mt-2 list-disc space-y-1 pl-6 text-ink">
              <li>
                The client&rsquo;s name (or a label of the
                practitioner&rsquo;s choosing).
              </li>
              <li>
                Per-treatment video consent flags (line drawing /
                grayscale / original) recorded by the practitioner on
                the client&rsquo;s behalf.
              </li>
              <li>
                References to the plans the practitioner has published
                for that client.
              </li>
            </ul>

            <h3 className="mt-6 font-heading text-base font-semibold text-ink">
              (c) Media captured on the practitioner&rsquo;s device
            </h3>
            <P>
              The homefit.studio iOS app captures short photos and
              videos of exercise demonstrations using the device camera.
              This media is processed{' '}
              <strong>on the practitioner&rsquo;s device</strong> into a
              line-drawing rendering. The line-drawing pipeline removes
              identifying detail (face, hair, skin tone, clothing
              specifics) by abstracting the human figure into a neutral
              outline. This is a privacy-by-design property of how
              homefit.studio works, not an after-the-fact filter.
            </P>
            <P>
              The original colour video and a grayscale rendering are
              also retained for use only when the client has explicitly
              consented to those treatments. If the client has not
              consented to a treatment, that treatment is unavailable on
              the client web player. Line-drawing is always available
              because it never identified the client in the first place
              (see section 14).
            </P>
            <P>
              We do not access photos, videos, microphone audio, or any
              other media on the practitioner&rsquo;s device beyond what
              they explicitly capture inside the homefit.studio app.
            </P>
          </Section>

          {/* 6. How we collect it */}
          <Section heading="6. How we collect personal information">
            <P>
              We collect personal information directly from the
              practitioner: when they sign up, when they create or edit a
              client record, when they publish a plan, and when they
              purchase credits. We do not buy, rent, or otherwise acquire
              personal information from third-party data brokers.
            </P>
            <P>
              For the limited purpose of fraud prevention on credit
              purchases, our payment processor PayFast may collect
              additional information from the practitioner directly
              (see section 18). We do not see card numbers.
            </P>
          </Section>

          {/* 7. Why we collect it */}
          <Section heading="7. Why we collect it (purpose limitation)">
            <P>
              POPIA section 13 requires us to collect personal
              information for a specific, explicitly defined and lawful
              purpose. Our purposes are:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>Account management</strong> &mdash; sign-in,
                practice membership, password resets.
              </li>
              <li>
                <strong>Capture, conversion, and storage of plan media</strong>{' '}
                &mdash; rendering the practitioner&rsquo;s exercise
                captures into the on-device line-drawing format and the
                consented grayscale / original variants.
              </li>
              <li>
                <strong>Plan delivery</strong> &mdash; serving the plan
                to the client&rsquo;s web browser via an unguessable
                share URL.
              </li>
              <li>
                <strong>Billing</strong> &mdash; consuming a credit at
                publish time, recording purchases, showing balance.
              </li>
              <li>
                <strong>Audit log</strong> &mdash; an append-only record
                of credit movements and plan publishes, retained for
                accounting compliance and dispute resolution.
              </li>
              <li>
                <strong>Referral programme</strong> &mdash; tracking
                referee signups and the rebate credits owed to the
                referrer, where the practitioner has opted in.
              </li>
            </ul>
            <P className="mt-4">
              <strong>What we do not do.</strong> We do not collect
              analytics or crash diagnostics. We do not use Firebase,
              Sentry, Mixpanel, Amplitude, Google Analytics, or any
              equivalent telemetry SDK. We do not show advertising and
              we do not profile you for advertising purposes. We do not
              sell or rent personal information to anyone.
            </P>
          </Section>

          {/* 8. Legal basis */}
          <Section heading="8. Legal basis for processing (POPIA s.11)">
            <P>
              POPIA section 11 lists the grounds on which personal
              information may be processed. We rely on the following:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>Consent</strong> &mdash; for the capture and
                playback of grayscale and original-colour media of
                clients, recorded per-treatment by the practitioner on
                the client&rsquo;s behalf. The line-drawing treatment is
                de-identified by design and does not require treatment-
                specific consent.
              </li>
              <li>
                <strong>Contract</strong> &mdash; for processing
                practitioner data necessary to deliver the homefit.studio
                service the practitioner has signed up for, including
                credit accounting and plan delivery.
              </li>
              <li>
                <strong>Legitimate interest</strong> &mdash; for the
                append-only audit ledger of credit movements and plan
                publishes. Retaining this record is necessary for
                accounting, dispute resolution, and detecting abuse, and
                the practitioner&rsquo;s reasonable expectation is that
                a service that sells credits keeps a log of how those
                credits were spent.
              </li>
              <li>
                <strong>Compliance with a legal obligation</strong>{' '}
                &mdash; for retaining payment records to the extent
                required by South African tax law (see section 11).
              </li>
            </ul>
          </Section>

          {/* 9. Sub-processors */}
          <Section heading="9. Sub-processors">
            <P>
              We use a small set of carefully chosen sub-processors. We
              do not transmit personal information to anyone else.
            </P>
            <div className="mt-4 overflow-x-auto rounded-md border border-surface-border">
              <table className="w-full text-left text-sm">
                <thead className="bg-surface-raised text-ink-muted">
                  <tr>
                    <th className="px-4 py-3 font-semibold">Sub-processor</th>
                    <th className="px-4 py-3 font-semibold">Purpose</th>
                    <th className="px-4 py-3 font-semibold">Hosting region</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-surface-border">
                  <tr>
                    <td className="px-4 py-3 align-top text-ink">Supabase</td>
                    <td className="px-4 py-3 align-top text-ink">
                      Authentication, Postgres database, object storage
                      for plan media.
                    </td>
                    <td className="px-4 py-3 align-top text-ink">
                      European Union
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3 align-top text-ink">Vercel</td>
                    <td className="px-4 py-3 align-top text-ink">
                      Web hosting and edge delivery for
                      <code className="mx-1">manage.homefit.studio</code>
                      and
                      <code className="mx-1">session.homefit.studio</code>.
                    </td>
                    <td className="px-4 py-3 align-top text-ink">
                      Global edge network
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3 align-top text-ink">PayFast</td>
                    <td className="px-4 py-3 align-top text-ink">
                      Payment processing for credit-bundle purchases.
                    </td>
                    <td className="px-4 py-3 align-top text-ink">
                      South Africa
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3 align-top text-ink">
                      Apple Inc.
                    </td>
                    <td className="px-4 py-3 align-top text-ink">
                      App Store and TestFlight distribution; receipt
                      validation for the iOS app.
                    </td>
                    <td className="px-4 py-3 align-top text-ink">
                      United States and Apple regional infrastructure
                    </td>
                  </tr>
                  <tr>
                    <td className="px-4 py-3 align-top text-ink">Hostinger</td>
                    <td className="px-4 py-3 align-top text-ink">
                      DNS only for the homefit.studio domain. No
                      personal information transits Hostinger.
                    </td>
                    <td className="px-4 py-3 align-top text-ink">
                      European Union
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <P className="mt-4 text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to advise whether
                we should publish the URL of each sub-processor&rsquo;s
                own privacy policy and DPA.]
              </em>
            </P>
          </Section>

          {/* 10. Cross-border */}
          <Section heading="10. Cross-border transfers (POPIA s.72)">
            <P>
              Some of our sub-processors host personal information
              outside South Africa. POPIA section 72 permits cross-
              border transfers in defined circumstances. We rely on:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>Section 72(1)(b)</strong> &mdash; the receiving
                jurisdiction (the European Union, where Supabase and
                Hostinger host) is subject to a law that provides an
                adequate level of protection (the EU General Data
                Protection Regulation), or the third party is bound by
                binding corporate rules or agreement to a substantially
                similar standard.
              </li>
              <li>
                <strong>Section 72(1)(a)</strong> &mdash; your consent,
                given by accepting this policy and continuing to use
                the service, for transfers to Vercel&rsquo;s global
                edge (which routes the request to whichever edge node
                is closest to the requester) and to Apple in the
                United States.
              </li>
            </ul>
            <P className="mt-4 text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm
                preferred wording for the s.72 ground we rely on for
                each sub-processor and to advise whether a separate
                consent step is needed at sign-up.]
              </em>
            </P>
          </Section>

          {/* 11. Storage & retention */}
          <Section heading="11. Storage and retention">
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>Soft-deleted records</strong> are retained for{' '}
                <strong>7 days</strong> in a recycle bin, after which
                they are removed from active storage. This window
                exists so a practitioner who deletes a plan or client
                in error can recover.
              </li>
              <li>
                <strong>Raw archive media</strong> (original colour and
                grayscale source files) are retained for{' '}
                <strong>90 days</strong> from the date of capture in a
                private storage bucket. After 90 days these are deleted
                from cloud storage; the line-drawing rendering remains
                available because it does not identify the client.
              </li>
              <li>
                <strong>Account deletion.</strong> A practitioner may
                request deletion of their account at any time by
                emailing{' '}
                <a
                  href="mailto:privacy@homefit.studio"
                  className="text-brand hover:underline"
                >
                  privacy@homefit.studio
                </a>
                . We will delete the account, the practitioner&rsquo;s
                personal information, and any client records and plans
                they own, except where retention is required by law
                (see below).
              </li>
              <li>
                <strong>Plan URL revocation.</strong> A practitioner
                can unpublish a plan at any time, which makes the
                client web player return a &ldquo;not available&rdquo;
                response for that URL.
              </li>
              <li>
                <strong>Ledger rows</strong> (credit purchases,
                consumptions, refunds, and rebates) are append-only
                and are retained for at least <strong>5 years</strong>{' '}
                to comply with South African tax-record retention
                requirements (Tax Administration Act, sections
                29&ndash;30).
              </li>
            </ul>
            <P className="mt-4 text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm the
                applicable retention period for accounting records and
                whether we need a longer retention for VAT-registered
                practices.]
              </em>
            </P>
          </Section>

          {/* 12. Security */}
          <Section heading="12. Security">
            <P>
              We apply security measures appropriate to the sensitivity
              of the information we process. These include:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>Row-level security</strong> on the database,
                scoped by practice membership, so a practitioner can
                only read or write data belonging to a practice they
                are a member of.
              </li>
              <li>
                <strong>RPC-only writes</strong> on financially
                sensitive tables (credit ledger, referral rebate
                ledger), so client code cannot insert, update, or
                delete rows directly.
              </li>
              <li>
                <strong>Signed URLs</strong> for raw-archive media,
                generated server-side and time-limited, so anonymous
                access to a private bucket is only possible for the
                exact path the practitioner has consented to expose.
              </li>
              <li>
                <strong>TLS in transit</strong> on every public
                endpoint, with HTTP Strict Transport Security and a
                Content Security Policy on the web surfaces.
              </li>
              <li>
                <strong>Password hashing</strong> handled by Supabase
                Auth using industry-standard algorithms; we never see
                or store plaintext passwords.
              </li>
            </ul>
            <P className="mt-4">
              No system is perfectly secure. If we become aware of a
              breach affecting your personal information, we will
              notify you and the Information Regulator as required by
              POPIA section 22.
            </P>
          </Section>

          {/* 13. Practitioner rights */}
          <Section heading="13. Your rights as a data subject (POPIA s.23–25)">
            <P>
              If you are a practitioner using the service, you have
              the following rights in respect of your own personal
              information:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>Access</strong> &mdash; you can request a copy
                of the personal information we hold about you.
              </li>
              <li>
                <strong>Correction</strong> &mdash; you can ask us to
                correct information that is inaccurate, irrelevant,
                excessive, out of date, incomplete, misleading, or
                obtained unlawfully.
              </li>
              <li>
                <strong>Deletion</strong> &mdash; you can ask us to
                delete or destroy your personal information, subject
                to retention obligations (see section 11).
              </li>
              <li>
                <strong>Objection</strong> &mdash; you can object to
                the processing of your personal information on
                reasonable grounds.
              </li>
              <li>
                <strong>Portability</strong> &mdash; on request we can
                provide your personal information in a structured
                machine-readable format.
              </li>
            </ul>
            <P className="mt-4">
              To exercise any of these rights, email{' '}
              <a
                href="mailto:privacy@homefit.studio"
                className="text-brand hover:underline"
              >
                privacy@homefit.studio
              </a>
              . We will respond within a reasonable time and at no
              cost. We may need to verify your identity before acting
              on the request.
            </P>
          </Section>

          {/* 14. Client rights */}
          <Section heading="14. Clients of practitioners">
            <P>
              If a practitioner has captured your exercise demonstration
              and shared a plan URL with you, the{' '}
              <strong>practitioner</strong> is the responsible party
              for your personal information &mdash; not homefit.studio.
              We act as an operator (processor) on the
              practitioner&rsquo;s behalf.
            </P>
            <P>
              If you want to access, correct, or delete the data the
              practitioner has captured of you, please contact your
              practitioner directly. They have the controls to do this
              inside the homefit.studio app.
            </P>
            <P>
              On the client web player, you can revoke per-treatment
              consent for the grayscale and original-colour videos at
              any time using the consent controls in the player. When
              you revoke consent the corresponding treatment is no
              longer available for playback.
            </P>
            <P>
              The line-drawing treatment is always available because
              the line-drawing pipeline never identified you in the
              first place. This is a property of how the rendering
              works (the human figure is abstracted to a neutral
              outline before the rendering reaches anyone&rsquo;s
              eyes), not a denial of your right to withdraw consent.
              If you nonetheless want the line-drawing rendering
              removed, contact your practitioner.
            </P>
            <P>
              If you cannot reach your practitioner or have a concern
              about how a practitioner has processed your data on our
              platform, you can email us at{' '}
              <a
                href="mailto:privacy@homefit.studio"
                className="text-brand hover:underline"
              >
                privacy@homefit.studio
              </a>{' '}
              and we will assist within the limits of our role as
              operator.
            </P>
          </Section>

          {/* 15. Children */}
          <Section heading="15. Children">
            <P>
              The homefit.studio app is intended for use by
              practitioners as part of their professional practice. We
              do not direct the homefit.studio app or web portal at
              children under the age of 13 as direct users.
            </P>
            <P>
              In the paediatric context, where a practitioner captures
              demonstrations of a child during a session, the{' '}
              <strong>practitioner</strong> is responsible for
              obtaining consent from the child&rsquo;s parent or
              guardian under POPIA section 35, and for recording the
              relevant per-treatment consent flags inside the app.
            </P>
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm the
                age threshold and any additional consent collection
                wording required for paediatric practice.]
              </em>
            </P>
          </Section>

          {/* 16. Cookies & local storage */}
          <Section heading="16. Cookies and local storage">
            <P>The web surfaces use a small number of first-party storage mechanisms:</P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                A <strong>Supabase auth cookie</strong> on{' '}
                <code>manage.homefit.studio</code>, set when you sign
                in, used to keep you signed in across page loads.
              </li>
              <li>
                A small <strong>active-practice cookie</strong> on{' '}
                <code>manage.homefit.studio</code> that remembers
                which practice you last viewed.
              </li>
              <li>
                <strong>localStorage</strong> on the client web player
                at <code>session.homefit.studio</code>, used to remember
                the treatment override (line drawing / B&amp;W /
                colour) the client has chosen for that plan URL.
              </li>
            </ul>
            <P className="mt-4">
              We do <strong>not</strong> use third-party cookies, we
              do not use advertising identifiers, and we do not load
              any analytics or advertising scripts.
            </P>
          </Section>

          {/* 17. App Tracking Transparency */}
          <Section heading="17. App Tracking Transparency">
            <P>
              The iOS app does not track you across other companies&rsquo;
              apps and websites, and we do not request the App Tracking
              Transparency permission. The privacy manifest shipped
              with the app sets <code>NSPrivacyTracking</code> to{' '}
              <code>false</code>.
            </P>
          </Section>

          {/* 18. Payments */}
          <Section heading="18. Payments">
            <P>
              Credit purchases on{' '}
              <code>manage.homefit.studio</code> are processed by{' '}
              <strong>PayFast</strong>. Card details are entered on
              PayFast&rsquo;s own secure pages. We never receive the
              full card number (PAN). What we receive and store is the
              transaction outcome: a payment identifier, the bundle
              purchased, the ZAR amount, the date, and a reference to
              the practice that the credits land in.
            </P>
            <P>
              We retain ledger rows for credit purchases, consumptions,
              refunds, and referral rebates for the period set out in
              section 11. PayFast&rsquo;s own privacy policy governs
              what they collect and retain on their side.
            </P>
            <P>
              We do not auto-renew, subscribe, or store payment methods
              for one-tap reuse on our side. Each top-up is an
              individual purchase initiated by the practitioner.
            </P>
          </Section>

          {/* 19. Changes */}
          <Section heading="19. Changes to this policy">
            <P>
              When we make a material change we will give reasonable
              advance notice through the in-app banner on the
              homefit.studio iOS app and through a sign-in banner on{' '}
              <code>manage.homefit.studio</code>. The version number
              and effective date at the top of this page reflect the
              current version. By continuing to use homefit.studio
              after a notified change takes effect, you accept the
              updated policy.
            </P>
          </Section>

          {/* 20. Complaints */}
          <Section heading="20. Complaints">
            <P>
              If you are unhappy with how we have handled your personal
              information, please email us first at{' '}
              <a
                href="mailto:privacy@homefit.studio"
                className="text-brand hover:underline"
              >
                privacy@homefit.studio
              </a>
              . We will investigate and respond within a reasonable
              time.
            </P>
            <P>
              If you are not satisfied with our response, you have the
              right to lodge a complaint with the Information Regulator
              of South Africa:
            </P>
            <ul className="mt-3 list-disc space-y-1 pl-6 text-ink">
              <li>
                Website:{' '}
                <a
                  href="https://inforegulator.org.za/"
                  className="text-brand hover:underline"
                  rel="noopener noreferrer"
                  target="_blank"
                >
                  https://inforegulator.org.za/
                </a>
              </li>
              <li>
                Email:{' '}
                <a
                  href="mailto:complaints.IR@justice.gov.za"
                  className="text-brand hover:underline"
                >
                  complaints.IR@justice.gov.za
                </a>
              </li>
            </ul>
          </Section>

          {/* 21. Contact */}
          <Section heading="21. Contact">
            <P>
              All privacy enquiries, data-subject requests, and
              correspondence relating to this policy should be sent to:
            </P>
            <div className="mt-3 rounded-md border border-surface-border bg-surface-base p-4 text-ink">
              <p>
                <strong>Carl Mostert, trading as homefit.studio</strong>
                <br />
                Email:{' '}
                <a
                  href="mailto:privacy@homefit.studio"
                  className="text-brand hover:underline"
                >
                  privacy@homefit.studio
                </a>
                <br />
                Postal:{' '}
                <em>
                  [BRACKETED PLACEHOLDER &mdash; physical / postal
                  address to be confirmed by Carl]
                </em>
              </p>
            </div>
          </Section>
        </article>

        <footer className="mt-16 border-t border-surface-border pt-6 text-xs text-ink-muted">
          <p>
            See also our{' '}
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

// ---------------------------------------------------------------------------
// Local prose helpers — keep the body of the policy declarative so a
// non-developer reviewer can scan the section structure quickly.
// ---------------------------------------------------------------------------

function Section({
  heading,
  children,
}: {
  heading: string;
  children: React.ReactNode;
}) {
  return (
    <section>
      <h2 className="font-heading text-xl font-semibold text-ink">
        {heading}
      </h2>
      <div className="mt-3 space-y-3">{children}</div>
    </section>
  );
}

function P({
  children,
  className = '',
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return <p className={`text-ink ${className}`}>{children}</p>;
}
