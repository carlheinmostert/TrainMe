'use client';

import { useEffect, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  PublicProfileError,
  type PracticePublicProfile,
} from '@/lib/supabase/api';

/**
 * Owner-only editor for the practice's public profile (slug + logo +
 * blurb + directory opt-in). Practitioners see a read-only view.
 *
 * The public profile is independent of premises Safe Mode toggles —
 * a practice can be directory-listed without enforcing Safe Mode at
 * any premises, and vice versa.
 */
type Props = {
  practiceId: string;
  practiceName: string;
  isOwner: boolean;
  initial: PracticePublicProfile;
};

const PUBLIC_BASE = 'https://session.homefit.studio/v/';
const BLURB_MAX = 280;

export function PracticeProfilePanel({
  practiceId,
  practiceName,
  isOwner,
  initial,
}: Props) {
  const [slug, setSlug] = useState<string>(initial.slug ?? '');
  const [logoUrl, setLogoUrl] = useState<string>(initial.logoUrl ?? '');
  const [blurb, setBlurb] = useState<string>(initial.blurb ?? '');
  const [listed, setListed] = useState<boolean>(initial.listed);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savedTick, setSavedTick] = useState(0);

  // Auto-suggest a slug on first edit if the field is blank.
  useEffect(() => {
    if (slug !== '' || initial.slug) return;
    (async () => {
      const api = createPortalApi(getBrowserClient());
      const suggested = await api.suggestPracticeSlug(practiceName);
      if (suggested) setSlug(suggested);
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [practiceName]);

  const slugValid = slug === '' || /^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$/.test(slug);
  const blurbValid = blurb.length <= BLURB_MAX;
  const canList = slug.length > 0;
  const dirty =
    (slug || '') !== (initial.slug ?? '')
    || (logoUrl || '') !== (initial.logoUrl ?? '')
    || (blurb || '') !== (initial.blurb ?? '')
    || listed !== initial.listed;

  const handleSave = async () => {
    setError(null);
    if (!slugValid) {
      setError('Slug must be 3–40 lowercase letters, digits, or hyphens.');
      return;
    }
    if (!blurbValid) {
      setError(`Blurb too long (max ${BLURB_MAX} characters).`);
      return;
    }
    if (listed && slug === '') {
      setError('Pick a slug before listing in the directory.');
      return;
    }
    setSaving(true);
    try {
      const api = createPortalApi(getBrowserClient());
      await api.setPracticePublicProfile({
        practiceId,
        slug: slug === '' ? null : slug,
        logoUrl: logoUrl.trim() === '' ? null : logoUrl.trim(),
        blurb: blurb.trim() === '' ? null : blurb.trim(),
        listed,
        // V2 fields — preserved through the V1 panel (it doesn't edit them).
        brandColor: initial.brandColor ?? null,
        tagline: initial.tagline ?? null,
        specialties: initial.specialties ?? null,
        contactEmail: initial.contactEmail ?? null,
        contactWhatsapp: initial.contactWhatsapp ?? null,
        contactWebsite: initial.contactWebsite ?? null,
      });
      setSavedTick((t) => t + 1);
    } catch (e) {
      if (e instanceof PublicProfileError) {
        setError(messageForKind(e));
      } else if (e instanceof Error) {
        setError(e.message);
      } else {
        setError('Save failed. Try again.');
      }
    } finally {
      setSaving(false);
    }
  };

  return (
    <section className="rounded-xl border border-surface-border bg-surface-base p-6">
      <div className="mb-4">
        <h2 className="font-heading text-xl font-bold">Public profile</h2>
        <p className="mt-1 text-xs text-ink-muted">
          A lightweight public page at{' '}
          <code className="rounded bg-surface-raised px-1 py-0.5 text-[11px] text-ink">
            {PUBLIC_BASE}
            {slug || 'your-slug'}
          </code>{' '}
          listing this practice and its premises. The directory toggle is
          independent of Safe Mode enforcement.
        </p>
      </div>

      {!isOwner && (
        <p className="mb-4 rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-xs text-ink-muted">
          Only the practice owner can edit the public profile.
        </p>
      )}

      <div className="flex flex-col gap-4">
        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium text-ink">URL slug</span>
          <div className="flex items-stretch overflow-hidden rounded-md border border-surface-border bg-surface-bg focus-within:border-brand">
            <span className="flex items-center bg-surface-raised px-3 text-xs text-ink-muted">
              {PUBLIC_BASE}
            </span>
            <input
              type="text"
              value={slug}
              onChange={(e) => setSlug(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '').slice(0, 40))}
              disabled={!isOwner}
              placeholder="virgin-active-sandton"
              maxLength={40}
              className="flex-1 bg-transparent px-3 py-2 text-ink placeholder:text-ink-muted focus:outline-none disabled:cursor-not-allowed disabled:text-ink-muted"
            />
          </div>
          {!slugValid && (
            <span className="text-xs text-error">
              3–40 chars, lowercase letters/digits/hyphens, no leading or
              trailing hyphen.
            </span>
          )}
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium text-ink">Logo URL (optional)</span>
          <input
            type="url"
            value={logoUrl}
            onChange={(e) => setLogoUrl(e.target.value)}
            disabled={!isOwner}
            placeholder="https://your-cdn.example/logo.png"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:cursor-not-allowed disabled:text-ink-muted"
          />
          <span className="text-xs text-ink-muted">
            Paste a public URL. Self-hosted upload arrives in a later wave.
          </span>
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <div className="flex items-baseline justify-between">
            <span className="font-medium text-ink">Blurb</span>
            <span
              className={
                blurb.length > BLURB_MAX
                  ? 'text-xs text-error'
                  : 'text-xs text-ink-muted'
              }
            >
              {blurb.length} / {BLURB_MAX}
            </span>
          </div>
          <textarea
            value={blurb}
            onChange={(e) => setBlurb(e.target.value)}
            disabled={!isOwner}
            rows={3}
            placeholder="One-paragraph summary of what this practice does, who it serves, and where it operates."
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:cursor-not-allowed disabled:text-ink-muted"
          />
        </label>

        <label className="flex items-start gap-2 text-sm">
          <input
            type="checkbox"
            checked={listed}
            onChange={(e) => setListed(e.target.checked)}
            disabled={!isOwner || !canList}
            className="mt-1 h-4 w-4 accent-brand"
          />
          <span>
            <span className="font-medium text-ink">List in the directory</span>
            <span className="block text-xs text-ink-muted">
              Makes <code className="text-ink">{PUBLIC_BASE}{slug || '…'}</code>{' '}
              publicly viewable. Premises are visible only if listed.
            </span>
          </span>
        </label>

        {error && (
          <div className="rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error">
            {error}
          </div>
        )}

        {isOwner && (
          <div className="flex items-center justify-end gap-3">
            {savedTick > 0 && !dirty && !error && (
              <span className="text-xs text-ink-muted">Saved ✓</span>
            )}
            <button
              type="button"
              onClick={handleSave}
              disabled={!dirty || saving || !slugValid || !blurbValid}
              className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-50"
            >
              {saving ? 'Saving…' : 'Save profile'}
            </button>
          </div>
        )}
      </div>
    </section>
  );
}

function messageForKind(err: PublicProfileError): string {
  switch (err.kind) {
    case 'slug-taken':
      return 'That slug is already taken by another practice.';
    case 'not-owner':
      return 'Only the practice owner can edit the public profile.';
    case 'slug-invalid':
      return 'Slug must be 3–40 lowercase letters, digits, or hyphens.';
    case 'blurb-too-long':
      return `Blurb too long (max ${BLURB_MAX} characters).`;
    case 'listed-without-slug':
      return 'Pick a slug before listing in the directory.';
    default:
      return err.message;
  }
}
