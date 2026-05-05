import Link from 'next/link';
import type { Metadata } from 'next';
import { BrandHeader } from '@/components/BrandHeader';
import {
  StepCreateClient,
  StepConsent,
  StepAvatar,
  StepNewSession,
  StepCamera,
  StepStudio,
  StepPreview,
  StepPublish,
  StepShare,
  ToolbarStrip,
  CameraIcon,
  RefineIcon,
  PreviewIcon,
  PublishIcon,
  ShareIcon,
  RefineRepsSets,
  RefineTrim,
  RefineHero,
  RefineCircuit,
} from './_illustrations';

export const metadata: Metadata = {
  title: 'Getting started — homefit.studio',
  description:
    'Your first session, step by step. From new client to shared plan in a few minutes.',
};

export default function GettingStartedPage() {
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
          Getting started
        </h1>
        <p className="mt-3 text-base text-ink-muted">
          Your first session, step by step. From new client to shared plan in a few minutes.
        </p>

        <div className="mt-6 rounded-md border border-brand/30 bg-brand/10 p-4 text-sm text-ink">
          You&rsquo;ve just signed in. Here&rsquo;s exactly what to do
          next. Four setup steps, then five toolbar stages &mdash;
          Camera, Refine, Preview, Publish, Share &mdash; and your
          client has a plan they can open in WhatsApp.
        </div>

        <ToolbarStrip />

        <article className="mt-12 space-y-16 text-base leading-relaxed text-ink">
          <Step
            number={1}
            heading="Create your first client"
            illustration={<StepCreateClient />}
          >
            <P>
              Home is your clients list. It&rsquo;s empty for now. Tap
              the coral <strong>+</strong> floating button at the
              bottom-right of the screen.
            </P>
            <P>
              A new client is minted with a placeholder name and you
              land on their detail screen. At the top, the name has a
              dashed underline &mdash; tap it and rename inline. No
              popup confirms the change. homefit never asks
              &ldquo;are you sure&rdquo;: actions land instantly and
              undo lives in a SnackBar at the bottom of the screen if
              you change your mind.
            </P>
          </Step>

          <Step
            number={2}
            heading="Set their consent"
            illustration={<StepConsent />}
          >
            <P>
              In the client detail screen, the consent section is
              collapsed by default. Tap to expand. You&rsquo;ll see
              three video-treatment toggles:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6">
              <li>
                <strong>Line drawing</strong> &mdash; always on. The
                on-device pipeline abstracts the human figure into a
                clean outline, which de-identifies the client.
                POPIA-friendly by design; consent for this treatment
                cannot be withdrawn because the client was never
                identifiable in the first place.
              </li>
              <li>
                <strong>Black &amp; white</strong> &mdash; optional.
                Useful when the client wants to see the actual
                movement without colour cues.
              </li>
              <li>
                <strong>Original colour</strong> &mdash; optional.
                The full colour video, exactly as captured.
              </li>
            </ul>
            <P>
              Below the treatments, an <strong>Avatar</strong> toggle
              controls whether the client&rsquo;s photo can be used
              in the practice list, and an <strong>Analytics</strong>{' '}
              toggle lets you see whether they actually opened the
              plan and worked through it. Both are opt-in.
            </P>
            <P>
              If you&rsquo;re not sure, leave it at line-drawing
              only. You can grant more later from the same screen.
            </P>
          </Step>

          <Step
            number={3}
            heading="Add their photo (optional)"
            illustration={<StepAvatar />}
          >
            <P>
              Tap the avatar circle near the top of the client
              screen. Choose from your camera roll. The photo lives
              only in your practice &mdash; it&rsquo;s how you
              recognise the client at a glance in your list. The
              client never sees this photo.
            </P>
            <P>
              You can skip this and come back to it later. Nothing
              downstream depends on it.
            </P>
          </Step>

          <Step
            number={4}
            heading="Create a session"
            illustration={<StepNewSession />}
          >
            <P>
              On the client screen, tap{' '}
              <strong>New Session</strong> (the coral pill near the
              bottom). The session opens directly in capture mode,
              titled with today&rsquo;s date and time. There&rsquo;s
              no setup screen and no form to fill in &mdash; the
              session exists, the client context comes with it, and
              the camera is already pointed at the floor.
            </P>
          </Step>

          <Step
            number={5}
            heading="Capture (Camera)"
            icon={<CameraIcon size={28} color="#9CA3AF" />}
            illustration={<StepCamera />}
          >
            <P>
              You&rsquo;re now in the session shell. Camera mode is
              full-screen with a shutter at the bottom. The shutter
              has two behaviours:
            </P>
            <ul className="mt-3 list-disc space-y-2 pl-6">
              <li>
                <strong>Short-press</strong> the shutter to take a
                photo.
              </li>
              <li>
                <strong>Long-press</strong> to record video. Aim for
                roughly <strong>three reps</strong> in each video
                &mdash; the player loops the video on the client
                side and counts reps as they follow along.
              </li>
              <li>
                Slide your thumb up while recording to{' '}
                <strong>lock</strong> hands-free. A coral border
                pulses around the screen edge while you&rsquo;re in
                the lock zone, so you know the gesture has armed.
              </li>
              <li>
                Pinch the viewfinder to zoom; the vertical lens
                pills on the right edge let you snap to{' '}
                <strong>0.5×</strong>, <strong>1×</strong>,{' '}
                <strong>2×</strong>, or <strong>3×</strong>.
              </li>
            </ul>
            <P>
              The line-drawing conversion happens on-device after
              each capture. You&rsquo;ll see a small spinner peek at
              the bottom-left, then the thumbnail. Conversion runs
              in the background &mdash; you can keep capturing while
              earlier clips render.
            </P>
          </Step>

          <Step
            number={6}
            heading="Refine (Studio)"
            icon={<RefineIcon size={28} color="#9CA3AF" />}
            illustration={<StepStudio />}
          >
            <P className="text-lg text-brand">
              All optional. All worth honouring.
            </P>
            <P>
              You can publish straight from Camera if you want
              &mdash; nothing below is mandatory. But this is where
              a stack of clips becomes a plan that lands well with
              the client. Each refinement is small. Together, they
              make the difference between &ldquo;here are some
              videos&rdquo; and &ldquo;here is your programme&rdquo;.
            </P>

            <RefineSubsection heading="Open the editor">
              <P>
                Tap a card to open the editor sheet. Or tap the{' '}
                <strong>Refine</strong> icon in the bottom workflow
                pill &mdash; same thing, opens the editor for the
                top card.
              </P>
            </RefineSubsection>

            <RefineSubsection
              heading="Reps and sets"
              illustration={<RefineRepsSets />}
            >
              <P>
                This is the piece that makes the workout actually
                structured. Set how many reps the client should do
                per set, and how many sets across the whole
                exercise. The player counts reps for them as they
                follow along.
              </P>
            </RefineSubsection>

            <RefineSubsection heading="Hold position">
              <P>
                Three options: <strong>per rep</strong>,{' '}
                <strong>end of set</strong>,{' '}
                <strong>end of exercise</strong>. Pick whichever
                matches how you cue the client in the room. The
                default is &ldquo;end of set&rdquo; &mdash; fine for
                most strength work.
              </P>
            </RefineSubsection>

            <RefineSubsection
              heading="Trim slider"
              illustration={<RefineTrim />}
            >
              <P>
                Two coral handles at the bottom of the editor
                preview. Drag them inward to clip the in and out
                points. Useful for cutting dead space at the start
                (you walking up to the camera) or the end (you
                reaching to stop recording). Drag-down pauses the
                video while you scrub; release resumes.
              </P>
            </RefineSubsection>

            <RefineSubsection
              heading="Hero frame"
              illustration={<RefineHero />}
            >
              <P>
                Pick the static thumbnail the client sees in their
                player and you see in your session list. Scrub
                through frames in the editor sheet header &mdash;
                pick the one that reads cleanly. It&rsquo;s the
                first impression of every exercise, so it matters.
              </P>
            </RefineSubsection>

            <RefineSubsection heading="Notes">
              <P>
                One-line cue, written for the client.
                &ldquo;Keep elbows tucked.&rdquo;
                &ldquo;Slow on the way down.&rdquo; Optional but
                high-leverage &mdash; the client reads this on the
                exercise card while they work.
              </P>
            </RefineSubsection>

            <RefineSubsection
              heading="Group into circuits"
              illustration={<RefineCircuit />}
            >
              <P>
                Use the gutter rail&rsquo;s circuit control to rope
                consecutive cards into a circuit. Set the number of
                cycles. The player will unroll the circuit so each
                round shows as its own slide.
              </P>
            </RefineSubsection>

            <RefineSubsection heading="Reorder">
              <P>
                Long-press a card and drag to reorder.{' '}
                <strong>Right-swipe</strong> a card to duplicate it
                (with undo). Rest periods auto-insert about every
                10 minutes; drag them where you want them.
              </P>
            </RefineSubsection>
          </Step>

          <Step
            number={7}
            heading="Preview"
            icon={<PreviewIcon size={28} color="#9CA3AF" />}
            illustration={<StepPreview />}
          >
            <P>
              Tap <strong>Preview</strong> in the workflow pill at
              the bottom. You see exactly what the client will see
              &mdash; the same player, the same pill matrix, the
              same timer. Swipe through the deck.
            </P>
            <P>
              Under each video, the three-treatment segmented
              control (<strong>Line</strong>, <strong>B&amp;W</strong>,{' '}
              <strong>Original</strong>) lets you sanity-check
              what&rsquo;s actually unlocked for this client. Greyed
              segments mean you haven&rsquo;t granted that consent
              &mdash; flip back to step 2 if you want to change
              that.
            </P>
          </Step>

          <Step
            number={8}
            heading="Publish"
            icon={<PublishIcon size={28} color="#9CA3AF" />}
            illustration={<StepPublish />}
          >
            <P>
              Tap <strong>Publish</strong>. The plan costs{' '}
              <strong>1 credit</strong> if estimated duration is 75
              minutes or less, <strong>2 credits</strong> if longer.
            </P>
            <P>
              The upload runs in the background. You can keep
              working &mdash; tap into another client, edit another
              session, close the app. A &ldquo;Published&nbsp;✓&rdquo;
              toast appears the moment the URL is live.
            </P>
          </Step>

          <Step
            number={9}
            heading="Share"
            icon={<ShareIcon size={28} color="#9CA3AF" />}
            illustration={<StepShare />}
          >
            <P>
              Tap <strong>Share</strong>. The iOS share sheet opens
              with the plan URL ready to send. WhatsApp is the most
              common path &mdash; the link unfurls into a clean
              preview with the homefit matrix logo, the
              client&rsquo;s name, and a short summary.
            </P>
            <P>
              Send it. Your client opens it in any browser &mdash;
              no app to install, no login, no account. They tap
              <strong> Start Workout</strong> and the session
              begins.
            </P>
          </Step>
        </article>

        <section className="mt-20 rounded-lg border border-surface-border bg-surface-base p-6">
          <h2 className="font-heading text-xl font-semibold text-ink">
            What happens next?
          </h2>
          <ul className="mt-4 list-disc space-y-3 pl-6 text-base text-ink">
            <li>
              When the client opens the link, you&rsquo;ll see an
              <strong> opened</strong> badge on the session card
              (only if you turned on analytics consent in step 2).
              If they finish the workout you&rsquo;ll see completion
              counts per exercise, too.
            </li>
            <li>
              You can edit and republish the plan freely.
              Non-structural edits (reps, sets, hold, notes) are
              always free. Structural edits (adding, deleting, or
              reordering exercises) are free for{' '}
              <strong>14 days</strong> after the client first opens
              the link &mdash; plenty of room for a follow-up
              session a week or two later.
            </li>
            <li>
              Need more credits? Open <strong>Credits</strong> in
              the dashboard. Top up whenever it suits you.
            </li>
          </ul>
        </section>

        <footer className="mt-16 border-t border-surface-border pt-6 text-xs text-ink-muted">
          <p>
            Questions about how your data is handled? See our{' '}
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
// Local prose helpers — match the privacy/terms idiom.
// ---------------------------------------------------------------------------

function Step({
  number,
  heading,
  icon,
  illustration,
  children,
}: {
  number: number;
  heading: string;
  icon?: React.ReactNode;
  illustration: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <section className="scroll-mt-20" id={`step-${number}`}>
      <div className="flex items-center gap-3">
        <span className="font-heading text-2xl font-bold text-brand">
          {number}.
        </span>
        {icon && (
          <span className="flex h-8 w-8 items-center justify-center" aria-hidden="true">
            {icon}
          </span>
        )}
        <h2 className="font-heading text-xl font-semibold text-ink sm:text-2xl">
          {heading}
        </h2>
      </div>
      <div className="mt-4 grid gap-6 sm:grid-cols-[1fr_auto] sm:items-start">
        <div className="space-y-4">{children}</div>
        <div className="sm:pt-2">{illustration}</div>
      </div>
    </section>
  );
}

function RefineSubsection({
  heading,
  illustration,
  children,
}: {
  heading: string;
  illustration?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div className="mt-6 border-l-2 border-surface-border pl-4">
      <h3 className="font-heading text-base font-semibold text-ink">
        {heading}
      </h3>
      <div className="mt-2 grid gap-4 sm:grid-cols-[1fr_auto] sm:items-start">
        <div className="space-y-2">{children}</div>
        {illustration && <div className="sm:pt-1">{illustration}</div>}
      </div>
    </div>
  );
}

function P({
  children,
  className,
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return <p className={className ? `text-ink ${className}` : 'text-ink'}>{children}</p>;
}
