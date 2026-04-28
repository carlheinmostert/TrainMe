import Link from 'next/link';
import type { Metadata } from 'next';
import { BrandHeader } from '@/components/BrandHeader';

export const metadata: Metadata = {
  title: 'Terms of Service — homefit.studio',
  description:
    'The terms governing your use of homefit.studio.',
};

const LAST_UPDATED = '2026-04-28';
const VERSION = '0.1-draft';

/**
 * Terms of Service — scaffold for legal review.
 *
 * Lighter scaffold than the privacy policy. Bracketed placeholders
 * dominate; pre-filled text is restricted to factual statements about
 * the service (what it is, the credit-bundle billing model, plan-
 * locking rules) so a lawyer&rsquo;s job is wording, not discovery.
 *
 * Static page — no interactivity, reachable without a session.
 */
export default function TermsOfServicePage() {
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
          Terms of Service
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
          African attorney. Bracketed placeholders mark the sections
          that need a lawyer&rsquo;s wording before publication.
        </div>

        <article className="mt-10 space-y-10 text-sm leading-relaxed text-ink">
          {/* 1. Acceptance */}
          <Section heading="1. Acceptance of these terms">
            <P>
              These Terms of Service (the &ldquo;Terms&rdquo;) govern
              your use of the homefit.studio iOS app and the web
              surfaces at <code>manage.homefit.studio</code> and{' '}
              <code>session.homefit.studio</code> (together, the
              &ldquo;Service&rdquo;). The Service is provided by{' '}
              <strong>Carl Mostert, trading as homefit.studio</strong>,
              a sole proprietorship in the Republic of South Africa
              (&ldquo;homefit.studio&rdquo;, &ldquo;we&rdquo;,
              &ldquo;our&rdquo;).
            </P>
            <P>
              By signing up, signing in, publishing a plan, purchasing
              credits, or otherwise using the Service, you accept these
              Terms. If you do not accept them, do not use the Service.
            </P>
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm
                precise acceptance language and capacity-to-contract
                wording for ZA jurisdiction.]
              </em>
            </P>
          </Section>

          {/* 2. Service description */}
          <Section heading="2. What homefit.studio is">
            <P>
              homefit.studio is a multi-tenant software-as-a-service
              platform that lets practitioners (biokineticists,
              physiotherapists, occupational therapists, fitness
              trainers) capture short demonstrations of exercises with
              their iOS device, convert those demonstrations into
              line-drawing renderings on-device, assemble a plan of
              exercises, and share the plan with their clients via a
              web URL.
            </P>
            <P>
              The Service is delivered through three surfaces: the iOS
              app for practitioners, the web portal at{' '}
              <code>manage.homefit.studio</code> for practice owners,
              and the anonymous client web player at{' '}
              <code>session.homefit.studio</code>.
            </P>
            <P className="text-ink-muted">
              The Service is offered &ldquo;as is&rdquo; and we may
              add, remove, or alter features as the platform evolves.
              Material changes are communicated as set out in
              section 12.
            </P>
          </Section>

          {/* 3. Account responsibilities */}
          <Section heading="3. Account responsibilities">
            <P>
              You are responsible for keeping your sign-in credentials
              secure and for all activity that occurs under your
              account. You must notify us immediately at{' '}
              <a
                href="mailto:privacy@homefit.studio"
                className="text-brand hover:underline"
              >
                privacy@homefit.studio
              </a>{' '}
              if you suspect unauthorised access.
            </P>
            <P>
              When you record a client and capture exercise
              demonstrations of that client, <strong>you</strong> are
              the responsible party (controller) for that client&rsquo;s
              personal information under POPIA. You must obtain valid
              consent from the client (or their parent or guardian, if
              applicable) before capturing media of them, and you must
              accurately record the per-treatment consent flags inside
              the homefit.studio app.
            </P>
            <P>
              You are responsible for ensuring the captures, plans,
              and notes you upload are accurate, lawful, and
              appropriate for the client they are intended for.
            </P>
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm
                indemnification wording for client-data breaches caused
                by the practitioner.]
              </em>
            </P>
          </Section>

          {/* 4. Billing */}
          <Section heading="4. Credits and billing">
            <P>
              The Service is billed on a prepaid credit model.
              Credit-bundle purchases are processed in South African
              Rand (ZAR) by PayFast. We do not offer subscriptions and
              we do not auto-renew.
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>One credit per plan</strong> is consumed when
                the plan is published, scaled by exercise count: 1
                credit for plans with 1&ndash;8 exercises, 2 credits
                for 9&ndash;15 exercises, 3 credits for 16 or more.
              </li>
              <li>
                Credits are <strong>non-refundable</strong> once
                consumed, except as required by law. Unused credits
                in your practice balance can be refunded within 14
                days of purchase by emailing{' '}
                <a
                  href="mailto:privacy@homefit.studio"
                  className="text-brand hover:underline"
                >
                  privacy@homefit.studio
                </a>
                ; we will reverse the original PayFast transaction.
              </li>
              <li>
                Credits do not expire so long as the practice account
                remains active.
              </li>
              <li>
                Treatment switching on the client web player (line
                drawing / B&amp;W / original) does not consume an
                additional credit.
              </li>
            </ul>
            <P className="mt-4 text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm the
                refund window, the wording around the
                Consumer Protection Act&rsquo;s cooling-off and
                non-refundability provisions, and any required
                statutory disclosures around digital-content
                purchases.]
              </em>
            </P>
          </Section>

          {/* 5. Plan-locking rules */}
          <Section heading="5. Plan editing and the unlock credit">
            <P>
              Once you publish a plan, you can edit it freely under
              the following rules:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>Non-structural edits</strong> (changing reps,
                sets, hold time, notes, filter parameters) are free
                forever.
              </li>
              <li>
                <strong>Structural edits</strong> (adding, deleting, or
                reordering exercises) are free indefinitely while your
                client has not yet opened the plan link.
              </li>
              <li>
                Once the client opens the plan link for the first
                time, you have <strong>14 days</strong> of free
                structural editing. After that window the plan locks
                against structural changes. The 14-day grace matches
                the typical practitioner / client follow-up cadence.
              </li>
              <li>
                You can unlock a locked plan for further structural
                editing by spending <strong>1 credit</strong>. The
                unlock credit pre-pays the next republish.
              </li>
            </ul>
            <P className="mt-4 text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm
                wording for the unlock credit as a service fee versus
                a digital-content top-up.]
              </em>
            </P>
          </Section>

          {/* 6. Acceptable use */}
          <Section heading="6. Acceptable use">
            <P>
              When using the Service you agree not to:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                Capture or upload material that is unlawful, defamatory,
                harassing, obscene, infringing, or that violates any
                person&rsquo;s privacy or dignity.
              </li>
              <li>
                Hold yourself out as a registered medical professional
                if you are not, or use the Service to deliver advice
                that requires a registration you do not hold (for
                example, biokinetics or physiotherapy registration with
                the relevant ZA regulatory body).
              </li>
              <li>
                Attempt to reverse-engineer, decompile, or interfere
                with the technical operation of the Service, or
                circumvent any security measure.
              </li>
              <li>
                Use the Service to send spam, conduct any unauthorised
                marketing, or upload malware.
              </li>
              <li>
                Resell, sublicense, or redistribute the Service to any
                third party other than your own clients in the normal
                course of your professional practice.
              </li>
            </ul>
            <P className="mt-4">
              We may suspend or terminate accounts that breach this
              section (see section 11).
            </P>
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to add any
                further prohibitions required, including ECT Act
                obligations and HPCSA / professional-body alignment.]
              </em>
            </P>
          </Section>

          {/* 7. Intellectual property */}
          <Section heading="7. Intellectual property and content licence">
            <P>
              You retain all intellectual property rights in the
              exercise demonstrations, photos, videos, and notes you
              capture and upload using the Service (&ldquo;Your
              Content&rdquo;).
            </P>
            <P>
              You grant homefit.studio a non-exclusive, worldwide,
              royalty-free licence to host, store, render, transcode,
              and serve Your Content solely for the purpose of
              delivering the Service to you and to the clients you
              choose to share plans with. The licence ends when you
              delete the relevant content (subject to retention
              periods set out in our Privacy Policy) or close your
              account.
            </P>
            <P>
              The homefit.studio name, logo, line-drawing rendering
              pipeline, and the underlying software and design system
              are owned by homefit.studio. Nothing in these Terms
              transfers any of those rights to you.
            </P>
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm
                content-licence scope and survival of licence
                post-termination for retained ledger material.]
              </em>
            </P>
          </Section>

          {/* 8. Disclaimers */}
          <Section heading="8. Disclaimers">
            <P>
              homefit.studio is a tool for practitioners to capture
              and share exercise demonstrations.{' '}
              <strong>
                It is not a medical device, it does not provide medical
                advice, and it does not diagnose, treat, cure, or
                prevent any disease.
              </strong>{' '}
              Any clinical judgement involved in selecting,
              prescribing, or sequencing exercises is the
              practitioner&rsquo;s, not ours.
            </P>
            <P>
              The Service is provided on an &ldquo;as is&rdquo; and
              &ldquo;as available&rdquo; basis. We make no warranty
              that the Service will be uninterrupted, error-free, or
              that it will achieve any particular adherence,
              compliance, or clinical outcome. To the maximum extent
              permitted by law, we exclude all implied warranties.
            </P>
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm
                wording aligns with Consumer Protection Act s.61
                (product liability) and any HPCSA disclaimers
                appropriate to the practitioner audience.]
              </em>
            </P>
          </Section>

          {/* 9. Limitation of liability */}
          <Section heading="9. Limitation of liability">
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to draft. The
                intent is to cap liability to the amount the
                practitioner paid us in the 12 months preceding the
                claim, exclude indirect / consequential / lost-profit
                damages, and align with what is enforceable under ZA
                law (in particular CPA section 51 unconscionable-
                conduct constraints).]
              </em>
            </P>
          </Section>

          {/* 10. Indemnification */}
          <Section heading="10. Indemnification">
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to draft. Cover
                practitioner indemnification of homefit.studio for
                claims arising from Your Content, your professional
                advice, your breach of these Terms, and any client-
                data consent failures on your side.]
              </em>
            </P>
          </Section>

          {/* 11. Termination */}
          <Section heading="11. Suspension and termination">
            <P>
              You can stop using the Service at any time. To delete
              your account and associated data, email{' '}
              <a
                href="mailto:privacy@homefit.studio"
                className="text-brand hover:underline"
              >
                privacy@homefit.studio
              </a>
              .
            </P>
            <P>
              We may suspend or terminate your account if you breach
              these Terms (in particular section 6), if your account
              is being used in a way that creates risk for clients or
              other practitioners, or if we are required to do so by
              law. Where reasonably possible we will give you notice
              and an opportunity to remedy the breach first.
            </P>
            <P>
              On termination, your right to use the Service ends
              immediately. Provisions that by their nature should
              survive (intellectual property, retention of audit
              ledger rows, limitation of liability,
              indemnification, governing law) survive termination.
            </P>
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to confirm
                refund treatment of unused credit balances on
                termination for cause vs. termination for
                convenience.]
              </em>
            </P>
          </Section>

          {/* 12. Changes to terms */}
          <Section heading="12. Changes to these terms">
            <P>
              We may update these Terms from time to time. When we
              make a material change we will give reasonable advance
              notice through the in-app banner on the homefit.studio
              iOS app and through a sign-in banner on{' '}
              <code>manage.homefit.studio</code>. By continuing to
              use the Service after a notified change takes effect,
              you accept the updated Terms.
            </P>
          </Section>

          {/* 13. Governing law & jurisdiction */}
          <Section heading="13. Governing law and jurisdiction">
            <P>
              These Terms are governed by the laws of the Republic
              of South Africa. Any dispute arising out of or in
              connection with these Terms is subject to the
              jurisdiction of the courts of the Western Cape, South
              Africa.
            </P>
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; Carl to confirm
                preferred jurisdiction (Western Cape vs. Gauteng);
                lawyer to confirm wording.]
              </em>
            </P>
          </Section>

          {/* 14. Dispute resolution */}
          <Section heading="14. Dispute resolution">
            <P className="text-ink-muted">
              <em>
                [BRACKETED PLACEHOLDER &mdash; lawyer to draft. Cover
                informal resolution (email first), then the chosen
                escalation path (CPA s.69 ombud / mediation /
                arbitration / courts) appropriate to a sole
                proprietor selling a low-value digital service to
                small practices.]
              </em>
            </P>
          </Section>

          {/* 15. Contact */}
          <Section heading="15. Contact">
            <P>
              All questions about these Terms should be sent to{' '}
              <a
                href="mailto:privacy@homefit.studio"
                className="text-brand hover:underline"
              >
                privacy@homefit.studio
              </a>
              .
            </P>
          </Section>
        </article>

        <footer className="mt-16 border-t border-surface-border pt-6 text-xs text-ink-muted">
          <p>
            See also our{' '}
            <Link href="/privacy" className="text-brand hover:underline">
              Privacy Policy
            </Link>
            .
          </p>
        </footer>
      </div>
    </main>
  );
}

// ---------------------------------------------------------------------------
// Local prose helpers — same shape as the privacy page so a reviewer
// scanning both finds a consistent section structure.
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
