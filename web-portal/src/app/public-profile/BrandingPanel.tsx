'use client';

import { useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  PublicProfileError,
  type PracticePublicProfile,
} from '@/lib/supabase/api';
import { BrandColorPicker } from './BrandColorPicker';
import { LogoUploader } from './LogoUploader';
import { SaveBar } from './SaveBar';

type Props = {
  practiceId: string;
  isOwner: boolean;
  profile: PracticePublicProfile;
  onSaved: (next: PracticePublicProfile) => void;
  defaultOpen?: boolean;
};

/**
 * Branding panel — logo + brand colour. Both surfaces cascade into
 * every published plan (Tasks 10-15). Identity-only fields stay
 * untouched here and are passed through to the save RPC verbatim.
 */
export function BrandingPanel({
  practiceId,
  isOwner,
  profile,
  onSaved,
  defaultOpen,
}: Props) {
  const [logoUrl, setLogoUrl] = useState<string | null>(profile.logoUrl);
  const [brandColor, setBrandColor] = useState<string | null>(
    profile.brandColor,
  );
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);

  const save = async () => {
    setError(null);
    setPending(true);
    try {
      const api = createPortalApi(getBrowserClient());
      await api.setPracticePublicProfile({
        practiceId,
        // Identity fields preserved verbatim — only branding edits here.
        slug: profile.slug,
        blurb: profile.blurb,
        listed: profile.listed,
        tagline: profile.tagline,
        specialties: profile.specialties,
        contactEmail: profile.contactEmail,
        contactWhatsapp: profile.contactWhatsapp,
        contactWebsite: profile.contactWebsite,
        // Branding edits.
        logoUrl,
        brandColor,
      });
      onSaved({
        ...profile,
        logoUrl,
        brandColor,
      });
      setSavedAt(Date.now());
    } catch (e) {
      // F-H3 fix (synthesis 2026-05-21): only toast typed
      // PublicProfileError (a domain-level rejection we expect — slug
      // taken, blurb too long, etc.). Anything else is a programmer
      // error or infrastructure failure that the user can't action;
      // log it and re-throw so it lands in Sentry / the dev console
      // instead of being silently mapped to a misleading toast string.
      if (e instanceof PublicProfileError) {
        setError(messageForKind(e));
      } else {
        // eslint-disable-next-line no-console
        console.error('[BrandingPanel] unexpected save error:', e);
        setError('Something went wrong saving — please try again.');
        throw e;
      }
    } finally {
      setPending(false);
    }
  };

  return (
    <details
      className="group rounded-lg border border-surface-border bg-surface-base p-5"
      open={defaultOpen}
    >
      <summary className="cursor-pointer text-base font-semibold text-ink">
        Branding
      </summary>
      <div className="mt-4 flex flex-col gap-5">
        <div>
          <div className="mb-2 text-sm font-medium text-ink">Logo</div>
          <LogoUploader
            practiceId={practiceId}
            isOwner={isOwner}
            currentUrl={logoUrl}
            onUploaded={setLogoUrl}
            onRemoved={() => setLogoUrl(null)}
          />
        </div>
        <div>
          <div className="mb-2 text-sm font-medium text-ink">Brand color</div>
          <BrandColorPicker
            value={brandColor}
            onChange={setBrandColor}
            isOwner={isOwner}
          />
        </div>
        {isOwner && (
          <SaveBar
            pending={pending}
            error={error}
            savedAt={savedAt}
            onSave={save}
            label="Save branding"
          />
        )}
      </div>
    </details>
  );
}

function messageForKind(err: PublicProfileError): string {
  switch (err.kind) {
    case 'not-owner':
      return 'Only the practice owner can edit branding.';
    case 'brand-color-invalid':
      return 'Brand color must be a 6-digit hex code.';
    default:
      return err.message;
  }
}
