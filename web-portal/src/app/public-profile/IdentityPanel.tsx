'use client';

import { useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  PublicProfileError,
  type PracticePublicProfile,
} from '@/lib/supabase/api';
import { SpecialtiesEditor } from './SpecialtiesEditor';
import { SaveBar } from './SaveBar';

type Props = {
  practiceId: string;
  isOwner: boolean;
  profile: PracticePublicProfile;
  onSaved: (next: PracticePublicProfile) => void;
  defaultOpen?: boolean;
};

// F-H1 fix (synthesis 2026-05-21): the hint promises a 3-40 char slug
// but the previous regex `^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$`
// permitted single-character slugs (the whole tail group was optional).
// Require head + body (>=1) + tail — minimum length 3, maximum 40.
const SLUG_RX = /^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$/;
const BLURB_MAX = 280;
const TAGLINE_MAX = 60;

/**
 * Identity + directory panel — slug, tagline, blurb, specialties,
 * contact channels, and the `listed` toggle. Branding fields
 * (logoUrl, brandColor) are preserved verbatim through the save RPC.
 */
export function IdentityPanel({
  practiceId,
  isOwner,
  profile,
  onSaved,
  defaultOpen,
}: Props) {
  const [slug, setSlug] = useState(profile.slug ?? '');
  const [tagline, setTagline] = useState(profile.tagline ?? '');
  const [blurb, setBlurb] = useState(profile.blurb ?? '');
  const [specialties, setSpecialties] = useState<string[]>(
    profile.specialties ?? [],
  );
  const [email, setEmail] = useState(profile.contactEmail ?? '');
  const [whatsapp, setWhatsapp] = useState(profile.contactWhatsapp ?? '');
  const [website, setWebsite] = useState(profile.contactWebsite ?? '');
  const [listed, setListed] = useState(profile.listed);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);

  const slugInvalid = slug !== '' && !SLUG_RX.test(slug);
  const wantsListedWithoutSlug = listed && (slug === '' || slugInvalid);

  const save = async () => {
    setError(null);
    if (wantsListedWithoutSlug) {
      setError('Pick a valid slug before listing in the directory.');
      return;
    }
    if (tagline.length > TAGLINE_MAX) {
      setError(`Tagline must be ${TAGLINE_MAX} characters or fewer.`);
      return;
    }
    if (blurb.length > BLURB_MAX) {
      setError(`Blurb must be ${BLURB_MAX} characters or fewer.`);
      return;
    }
    if (website && !/^https?:\/\//i.test(website)) {
      setError('Website must start with https://');
      return;
    }
    setPending(true);
    try {
      const api = createPortalApi(getBrowserClient());
      const nextSlug = slug || null;
      const nextTagline = tagline || null;
      const nextBlurb = blurb || null;
      const nextSpecialties = specialties.length > 0 ? specialties : null;
      const nextEmail = email || null;
      const nextWhatsapp = whatsapp || null;
      const nextWebsite = website || null;

      await api.setPracticePublicProfile({
        practiceId,
        slug: nextSlug,
        // Branding fields preserved verbatim.
        logoUrl: profile.logoUrl,
        brandColor: profile.brandColor,
        blurb: nextBlurb,
        listed,
        tagline: nextTagline,
        specialties: nextSpecialties,
        contactEmail: nextEmail,
        contactWhatsapp: nextWhatsapp,
        contactWebsite: nextWebsite,
      });
      onSaved({
        ...profile,
        slug: nextSlug,
        blurb: nextBlurb,
        listed,
        tagline: nextTagline,
        specialties: nextSpecialties,
        contactEmail: nextEmail,
        contactWhatsapp: nextWhatsapp,
        contactWebsite: nextWebsite,
      });
      setSavedAt(Date.now());
    } catch (e) {
      if (e instanceof PublicProfileError) {
        setError(messageForKind(e));
      } else if (e instanceof Error) {
        setError(e.message);
      } else {
        setError('Save failed.');
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
        Identity &amp; directory
      </summary>
      <div className="mt-4 flex flex-col gap-4">
        <Field label="Tagline" hint={`${tagline.length} / ${TAGLINE_MAX}`}>
          <input
            type="text"
            value={tagline}
            maxLength={TAGLINE_MAX}
            onChange={(e) => setTagline(e.target.value)}
            disabled={!isOwner}
            placeholder="Short marketing line"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field label="Blurb" hint={`${blurb.length} / ${BLURB_MAX}`}>
          <textarea
            value={blurb}
            maxLength={BLURB_MAX}
            onChange={(e) => setBlurb(e.target.value)}
            disabled={!isOwner}
            rows={3}
            placeholder="A paragraph describing your practice."
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field label="Specialties" hint={`${specialties.length} / 8`}>
          <SpecialtiesEditor
            value={specialties}
            onChange={setSpecialties}
            isOwner={isOwner}
          />
        </Field>
        <Field label="Email">
          <input
            type="email"
            value={email}
            maxLength={120}
            onChange={(e) => setEmail(e.target.value)}
            disabled={!isOwner}
            placeholder="hello@example.com"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field label="WhatsApp">
          <input
            type="tel"
            value={whatsapp}
            maxLength={20}
            onChange={(e) => setWhatsapp(e.target.value)}
            disabled={!isOwner}
            placeholder="+27 82 123 4567"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field label="Website">
          <input
            type="url"
            value={website}
            maxLength={200}
            onChange={(e) => setWebsite(e.target.value)}
            disabled={!isOwner}
            placeholder="https://yourpractice.co.za"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
        </Field>
        <Field
          label="Slug"
          hint="lowercase letters, digits, hyphens · 3–40 chars"
        >
          <input
            type="text"
            value={slug}
            onChange={(e) =>
              setSlug(
                e.target.value
                  .toLowerCase()
                  .replace(/[^a-z0-9-]/g, '')
                  .slice(0, 40),
              )
            }
            disabled={!isOwner}
            placeholder="your-practice"
            className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-60"
          />
          {slugInvalid && (
            <p className="mt-1 text-xs text-error">
              Slug must be 3–40 lowercase letters, digits, or hyphens.
            </p>
          )}
        </Field>
        <label className="flex items-center gap-2 text-sm text-ink">
          <input
            type="checkbox"
            checked={listed}
            onChange={(e) => setListed(e.target.checked)}
            disabled={!isOwner}
            className="h-4 w-4 accent-brand"
          />
          <span>
            List in the directory at{' '}
            <code className="text-ink">
              session.homefit.studio/v/{slug || 'your-slug'}
            </code>
          </span>
        </label>
        {isOwner && (
          <SaveBar
            pending={pending}
            error={error}
            savedAt={savedAt}
            onSave={save}
            label="Save profile"
          />
        )}
      </div>
    </details>
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
      return `Blurb must be ${BLURB_MAX} characters or fewer.`;
    case 'tagline-too-long':
      return `Tagline must be ${TAGLINE_MAX} characters or fewer.`;
    case 'specialties-too-many':
      return 'Maximum 8 specialties.';
    case 'contact-too-long':
      return 'Contact field is too long.';
    case 'website-invalid':
      return 'Website must start with https://';
    case 'listed-without-slug':
      return 'Pick a valid slug before listing in the directory.';
    default:
      return err.message;
  }
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      <div className="flex items-baseline justify-between">
        <span className="font-medium text-ink">{label}</span>
        {hint && <span className="text-xs text-ink-muted">{hint}</span>}
      </div>
      {children}
    </label>
  );
}
