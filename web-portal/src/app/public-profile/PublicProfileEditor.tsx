'use client';

import { useState } from 'react';
import type { PracticePublicProfile } from '@/lib/supabase/api';
import { BrandingPanel } from './BrandingPanel';
import { IdentityPanel } from './IdentityPanel';

type Props = {
  practiceId: string;
  practiceName: string;
  isOwner: boolean;
  initial: PracticePublicProfile | null;
  initialSection?: 'branding' | 'identity';
  /**
   * Hostname-only label for the player surface this portal is paired
   * with (e.g. `session.homefit.studio` on prod,
   * `staging.session.homefit.studio` on staging). Derived server-side
   * from the request `host` header so the inline `<code>` previews
   * reflect the deploy ring the practitioner is looking at.
   */
  playerHostLabel: string;
};

/**
 * Client-side shell that owns the in-memory `PracticePublicProfile`
 * state. Each panel saves through its own `SaveBar` and bubbles the
 * fresh snapshot up via `onSaved`, so cross-panel reads (e.g. the
 * Identity panel needing the latest brandColor for its preview) stay
 * coherent without a full page round-trip.
 */
export function PublicProfileEditor({
  practiceId,
  practiceName,
  isOwner,
  initial,
  initialSection,
  playerHostLabel,
}: Props) {
  // Build a defaults-shaped profile when the practice hasn't saved one
  // yet, so panel reads never have to null-check every field.
  const seed: PracticePublicProfile = initial ?? {
    practiceId,
    practiceName,
    slug: null,
    logoUrl: null,
    blurb: null,
    listed: false,
    brandColor: null,
    tagline: null,
    specialties: null,
    contactEmail: null,
    contactWhatsapp: null,
    contactWebsite: null,
  };
  const [profile, setProfile] = useState<PracticePublicProfile>(seed);

  // Safe Mode Transparency — Phase A (2026-05-22).
  // Coral-bordered notice that surfaces when any of the three
  // practice-controlled gate items is missing. The six-point Safe Mode
  // gate cannot pass for any practitioner in this practice until all
  // three are set + the practice is listed.
  const safeModeMissing = [
    !profile.slug ? 'a slug' : null,
    !profile.blurb ? 'a blurb' : null,
    !profile.listed ? 'the directory listing' : null,
  ].filter((x): x is string => x !== null);
  const safeModeBlocked = safeModeMissing.length > 0;

  return (
    <div className="flex flex-col gap-3">
      {safeModeBlocked && (
        <div className="rounded-md border-2 border-brand bg-surface-raised px-4 py-3 text-sm">
          <div className="font-semibold text-brand">
            Important: complete the fields below to enable Safe Mode
          </div>
          <p className="mt-1 text-ink-muted">
            Your practitioners cannot record in any Safe-Mode-enforced
            premises until you set {safeModeMissing.join(', ')}. Safe Mode
            obscures bystanders on the public live page — bystanders in
            turn see your practice name + practitioner identities, so this
            information needs to be public.
          </p>
        </div>
      )}
      {!isOwner && (
        <div className="rounded-md border border-surface-border bg-surface-raised px-4 py-3 text-sm text-ink-muted">
          Only the practice owner can edit branding &amp; profile. You can view
          what they have set.
        </div>
      )}
      <BrandingPanel
        practiceId={practiceId}
        isOwner={isOwner}
        profile={profile}
        onSaved={setProfile}
        defaultOpen={initialSection !== 'identity'}
      />
      <IdentityPanel
        practiceId={practiceId}
        isOwner={isOwner}
        profile={profile}
        onSaved={setProfile}
        defaultOpen={initialSection === 'identity'}
        playerHostLabel={playerHostLabel}
      />
    </div>
  );
}
