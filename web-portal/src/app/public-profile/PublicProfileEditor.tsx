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

  return (
    <div className="flex flex-col gap-3">
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
      />
    </div>
  );
}
