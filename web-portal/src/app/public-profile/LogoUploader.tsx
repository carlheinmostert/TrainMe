'use client';

import { useEffect, useRef, useState } from 'react';
import { getBrowserClient } from '@/lib/supabase-browser';

type Props = {
  practiceId: string;
  isOwner: boolean;
  currentUrl: string | null;
  onUploaded: (url: string) => void;
  onRemoved: () => void;
};

const MAX_BYTES = 1_048_576; // 1 MB
// SVG is intentionally excluded — SVG can carry inline <script>/<foreignObject>
// payloads that render in any surface that draws the logo via <img src=>.
// The storage policy (20260521170000_branding_storage_policies.sql) also blocks
// SVG at the bucket layer; this is the matching client-side gate.
const ACCEPT = 'image/png,image/jpeg';
const ALLOWED_MIMES = new Set(['image/png', 'image/jpeg']);

/**
 * Uploads the practice logo to the public `media` bucket under
 * `branding/{practiceId}/logo.{ext}` and hands the cache-busted public
 * URL back to the panel. Remove is local-state only — the panel's
 * save bar persists the `null` value through `setPracticePublicProfile`.
 *
 * Storage RLS scopes write access on this prefix to practice owners;
 * the upload fails with a server-side error if the caller isn't an
 * owner, surfaced via the local `error` state.
 */
export function LogoUploader({
  practiceId,
  isOwner,
  currentUrl,
  onUploaded,
  onRemoved,
}: Props) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState(false);
  // F-H2 / Q-H4 fix (synthesis 2026-05-21): track the most recent upload
  // via a monotonic token so a slow first pick can't clobber a fast
  // second pick's state. The latest token wins; older completions are
  // ignored (storage state still mutates, but `onUploaded` + UI flag
  // only fire for the winning token).
  const inflightToken = useRef<number>(0);
  // Inline "Uploaded" pill, mirrors the SaveBar pattern in BrandingPanel.
  const [savedAt, setSavedAt] = useState<number | null>(null);

  // Auto-dismiss the success pill after 3s so the panel doesn't keep
  // shouting at the user once they're done.
  useEffect(() => {
    if (savedAt == null) return;
    const id = window.setTimeout(() => setSavedAt(null), 3000);
    return () => window.clearTimeout(id);
  }, [savedAt]);

  const handleFile = async (file: File) => {
    setError(null);
    if (file.size > MAX_BYTES) {
      setError(
        `Logo too large (${(file.size / 1048576).toFixed(1)} MB, max 1 MB).`,
      );
      return;
    }
    if (!ALLOWED_MIMES.has(file.type)) {
      setError('Logo must be PNG or JPG.');
      return;
    }
    const token = Date.now();
    inflightToken.current = token;
    setUploading(true);
    try {
      const ext = file.name.split('.').pop()?.toLowerCase() ?? 'png';
      const path = `branding/${practiceId}/logo.${ext}`;
      const supabase = getBrowserClient();
      // F-H2: wrap in try/catch — `supabase.storage.upload` can reject
      // (network drop, AbortError, CORS) and that rejection used to land
      // in no catch, leaving the spinner stuck + no message for the user.
      const { error: uploadError } = await supabase.storage
        .from('media')
        .upload(path, file, { upsert: true, contentType: file.type });
      // Q-H4: stale-token check — a newer pick has started, abandon
      // this completion entirely.
      if (inflightToken.current !== token) return;
      if (uploadError) {
        setError(uploadError.message || 'Upload failed.');
        // eslint-disable-next-line no-console
        console.error('[LogoUploader] upload error:', uploadError);
        return;
      }
      const { data: pub } = supabase.storage.from('media').getPublicUrl(path);
      // Cache-bust so the browser fetches the new bytes immediately.
      const url = `${pub.publicUrl}?v=${token}`;
      onUploaded(url);
      setSavedAt(token);
    } catch (e) {
      // Stale-token check on the throw path too — a newer pick that's
      // already finished shouldn't be undone by a late rejection.
      if (inflightToken.current !== token) return;
      const msg = e instanceof Error ? e.message : 'Upload failed.';
      setError(msg);
      // eslint-disable-next-line no-console
      console.error('[LogoUploader]', e);
    } finally {
      // Only the winning token clears the spinner — older completions
      // would otherwise turn it off prematurely while a newer upload
      // is still in flight.
      if (inflightToken.current === token) setUploading(false);
    }
  };

  const onPick = () => fileRef.current?.click();
  const onChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) void handleFile(file);
    e.target.value = '';
  };
  const onDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const file = e.dataTransfer.files?.[0];
    if (file) void handleFile(file);
  };
  const onDragOver = (e: React.DragEvent) => {
    e.preventDefault();
    if (isOwner) setDragOver(true);
  };
  const onDragLeave = () => setDragOver(false);

  return (
    <div className="flex flex-col gap-2">
      <input
        type="file"
        accept={ACCEPT}
        ref={fileRef}
        onChange={onChange}
        className="hidden"
        disabled={!isOwner}
      />
      <div
        onClick={isOwner ? onPick : undefined}
        onDrop={isOwner ? onDrop : undefined}
        onDragOver={isOwner ? onDragOver : undefined}
        onDragLeave={isOwner ? onDragLeave : undefined}
        className={`flex items-center gap-4 rounded-lg border-2 border-dashed px-4 py-4 ${
          dragOver
            ? 'border-brand bg-brand/5'
            : 'border-surface-border bg-surface-bg'
        } ${
          isOwner
            ? 'cursor-pointer hover:border-brand/60'
            : 'cursor-not-allowed opacity-60'
        }`}
      >
        {currentUrl ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={currentUrl}
            alt="Logo"
            className="h-14 w-14 rounded object-contain bg-surface-base"
          />
        ) : (
          <div className="flex h-14 w-14 items-center justify-center rounded bg-surface-base text-2xl text-ink-muted">
            <span aria-hidden>★</span>
          </div>
        )}
        <div className="flex-1">
          <div className="text-sm text-ink">
            {currentUrl ? 'Replace logo' : 'Upload a logo'}
          </div>
          <div className="text-xs text-ink-muted">
            PNG or JPG · ≤ 1 MB · square or landscape works
          </div>
        </div>
        {currentUrl && isOwner && (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              onRemoved();
            }}
            className="text-xs text-ink-muted underline decoration-dotted hover:text-error"
          >
            Remove
          </button>
        )}
      </div>
      {uploading && <p className="text-xs text-ink-muted">Uploading…</p>}
      {!uploading && savedAt != null && (
        <p className="text-xs text-emerald-500" role="status" aria-live="polite">
          Uploaded ✓
        </p>
      )}
      {error && (
        <p className="text-xs text-error" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}
