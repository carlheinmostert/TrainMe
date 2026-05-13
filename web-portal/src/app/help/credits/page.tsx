import Link from 'next/link';
import type { Metadata } from 'next';
import { BrandHeader } from '@/components/BrandHeader';

export const metadata: Metadata = {
  title: 'What are credits? — homefit.studio',
  description:
    'How publishing credits work in homefit.studio: one credit per plan, free re-publishes for non-structural edits, and what happens when you run out.',
};

/**
 * Help article — Credits explainer.
 *
 * **Apple Reader-App compliance (App Store Review Guideline 3.1.1).**
 * This is the page that opens when the practitioner taps the `?` glyph
 * on the out-of-credits chip in the iOS app. Reviewers will follow
 * that tap target. The page MUST:
 *
 *   - Read as **informational** explainer copy, not a sales page.
 *   - Show **no prices**, ever. Not in body text, not in tables, not
 *     in inline examples.
 *   - Carry **no "Buy now" / "Purchase credits" CTAs**. No buttons that
 *     funnel into a checkout flow. The page exists to explain the
 *     account model — that's the entire job.
 *   - Be reachable without authentication (Apple reviewers visit
 *     public URLs cold).
 *
 * The wider portal does have a `/credits` purchase page for signed-in
 * owners — that's outside the iOS-app linking surface and stays where
 * it is. This page deliberately does not link to it; if a curious
 * visitor wants to manage their account they navigate the portal
 * themselves from a desktop browser.
 *
 * Static page — no client component, no interactivity. The header
 * renders without `showSignOut` so the page is reachable cold.
 */
export default function HelpCreditsPage() {
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
          What are credits, and what happens when you run out?
        </h1>
        <p className="mt-3 text-base text-ink-muted">
          A short explainer for the way publishing works in
          homefit.studio.
        </p>

        <article className="mt-10 space-y-12 text-base leading-relaxed text-ink">
          <Section heading="How credits work">
            <P>
              Every time you publish a plan for a client, the practice
              spends <strong>credits</strong>. A credit is the unit of
              publishing capacity — it&rsquo;s scoped to the practice,
              not the individual practitioner, so any practitioner in
              the practice can use the shared balance to publish.
            </P>
            <P>
              The cost per plan is duration-based:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>1 credit</strong> for a plan with an estimated
                duration of <strong>75 minutes or less</strong>. The
                vast majority of real-world plans land here.
              </li>
              <li>
                <strong>2 credits</strong> for a plan longer than 75
                minutes. This is an anti-abuse guard, not the typical
                case.
              </li>
            </ul>
            <P>
              The estimate is calculated from your reps, sets, hold
              positions, inter-set rests, and any rest periods you
              dropped between exercises. You can see it on the publish
              screen before you spend anything.
            </P>
          </Section>

          <Section heading="Free re-publishes">
            <P>
              Once a plan is published, you can refine it without
              spending more credits — within reasonable limits. The
              rule is about <em>kind of edit</em>, not how often you
              edit:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>Non-structural edits</strong> are always free,
                forever. That covers reps, sets, hold position,
                inter-set rest, hero frame, trim window, notes, and
                consent changes. Tweak as often as you like — these
                never cost a credit.
              </li>
              <li>
                <strong>Structural edits</strong> — adding, deleting,
                or reordering exercises — are free as long as the
                client hasn&rsquo;t opened the plan yet. The moment
                they tap the link, a <strong>14-day grace window</strong>{' '}
                opens. Within those two weeks you can still add /
                delete / reorder freely, no credit cost. The window
                matches typical follow-up cadence: most clients return
                for a check-in one to two weeks later, and you need
                the freedom to refine the plan based on what you
                observe.
              </li>
              <li>
                After the 14-day window closes, the plan is locked for
                structural edits. You can still make non-structural
                refinements forever. If you do need to restructure the
                plan after the lock, you can spend 1 credit to unlock
                it for the next republish.
              </li>
            </ul>
          </Section>

          <Section heading="When you run out">
            <P>
              When the practice balance hits zero, the credits chip on
              the Home screen of the iOS app turns into a filled coral
              pill with a <strong>0</strong> and a help glyph (the same
              link that brought you here).
            </P>
            <P>
              Publish is blocked at zero. Capture, editing, preview,
              and sharing a previously published plan all continue to
              work — running out of credits only affects the moment
              you try to publish a <em>new</em> plan or a structural
              update to an existing locked plan.
            </P>
            <P>
              Account management for the practice — including topping
              up — lives on the practice manager web portal at{' '}
              <code className="font-mono text-brand">
                manage.homefit.studio
              </code>
              . The practice owner manages the balance from there at a
              desktop browser, on their own time. We don&rsquo;t
              surface that workflow inside the iOS app because credits
              are a practice-level concern, not a session-by-session
              one.
            </P>
          </Section>

          <Section heading="Who can manage the balance?">
            <P>
              Practices have two roles:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6 text-ink">
              <li>
                <strong>Owner</strong> — manages the practice account,
                including the credit balance.
              </li>
              <li>
                <strong>Practitioner</strong> — consumes credits from
                the shared balance to publish plans for their clients.
              </li>
            </ul>
            <P>
              If you&rsquo;re a practitioner in a practice you
              don&rsquo;t own and the balance hits zero, the owner is
              the person who handles top-up. The owner&rsquo;s email
              is visible in the practice switcher on the Home screen.
            </P>
          </Section>

          <Section heading="Multiple practices">
            <P>
              If you belong to more than one practice — for example,
              you&rsquo;re an owner of your own practice and also a
              practitioner in a clinic — each practice has its own
              independent credit balance. The chip at the top of Home
              always shows the balance for the practice you&rsquo;re
              currently working in. Tap the practice chip on the left
              of Home to switch between them.
            </P>
          </Section>
        </article>

        <footer className="mt-16 border-t border-surface-border pt-6 text-sm text-ink-muted">
          <p>
            Questions? Email us at{' '}
            <a
              href="mailto:support@homefit.studio"
              className="text-brand hover:underline"
            >
              support@homefit.studio
            </a>
            .
          </p>
          <p className="mt-2">
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

// ---------------------------------------------------------------------------
// Local prose helpers — match the privacy / terms / getting-started idiom.
// ---------------------------------------------------------------------------

function Section({
  heading,
  children,
}: {
  heading: string;
  children: React.ReactNode;
}) {
  return (
    <section className="scroll-mt-20">
      <h2 className="font-heading text-xl font-semibold text-ink sm:text-2xl">
        {heading}
      </h2>
      <div className="mt-4 space-y-4">{children}</div>
    </section>
  );
}

function P({ children }: { children: React.ReactNode }) {
  return <p className="text-ink">{children}</p>;
}
