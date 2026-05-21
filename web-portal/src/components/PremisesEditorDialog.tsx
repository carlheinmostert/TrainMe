'use client';

import { useCallback, useEffect, useState } from 'react';
import dynamic from 'next/dynamic';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  type PracticePremises,
  PremisesError,
} from '@/lib/supabase/api';
import { AddressSearchInput, type AddressMatch } from './AddressSearchInput';
import type { PolygonGeoJSON, PolygonStats } from './PremisesPolygonEditor';

// Leaflet writes to `window` at import time, so the editor must be SSR-skipped.
const PremisesPolygonEditor = dynamic(
  () =>
    import('./PremisesPolygonEditor').then((m) => m.PremisesPolygonEditor),
  { ssr: false, loading: () => (
    <div className="h-96 w-full animate-pulse rounded-lg border border-surface-border bg-surface-base" />
  ) },
);

/**
 * Edit-existing or create-new premises dialog. Wraps the polygon editor
 * + the name / address / Safe Mode form fields, posts via PortalApi.
 *
 * Mounted by [PremisesListPanel] when the user clicks "Add premises" or
 * "Edit" on a row. Closes on save success (with onSaved called so the
 * parent can refresh).
 */
type Props = {
  practiceId: string;
  initial: PracticePremises | null;
  onClose: () => void;
  onSaved: () => void;
};

export function PremisesEditorDialog({
  practiceId,
  initial,
  onClose,
  onSaved,
}: Props) {
  const [name, setName] = useState(initial?.name ?? '');
  const [address, setAddress] = useState(initial?.address ?? '');
  const [safeMode, setSafeMode] = useState(initial?.safeModeEnforced ?? true);
  const [polygon, setPolygon] = useState<PolygonGeoJSON | null>(() => {
    if (!initial) return null;
    try {
      return JSON.parse(initial.polygonGeoJson) as PolygonGeoJSON;
    } catch {
      return null;
    }
  });
  const [stats, setStats] = useState<PolygonStats>({
    vertexCount: 0,
    areaM2: 0,
    isValid: false,
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [geo, setGeo] = useState<{ lat: number; lng: number } | null>(null);
  type GeoStatus =
    | { kind: 'idle' }
    | { kind: 'requesting' }
    | { kind: 'ok' }
    | { kind: 'denied' }
    | { kind: 'unavailable'; message: string };
  const [geoStatus, setGeoStatus] = useState<GeoStatus>({ kind: 'idle' });
  // Bumped each time the user picks an address-search result so the map
  // pans to the new centre. The `nonce` lets the editor's effect
  // re-trigger even if the user picks the same result twice.
  const [centerTrigger, setCenterTrigger] = useState<
    { lat: number; lng: number; zoom?: number; nonce: number } | null
  >(null);

  // Shared geolocation request — used by both the auto-attempt on dialog
  // open AND the explicit "Use my location" button. A user-gesture call
  // gets the browser to re-prompt even when permission state was previously
  // denied (or when the auto-call hit a sticky deny from a prior session).
  const requestLocation = useCallback(() => {
    if (!('geolocation' in navigator)) {
      setGeoStatus({
        kind: 'unavailable',
        message: 'Geolocation API not supported in this browser.',
      });
      return;
    }
    setGeoStatus({ kind: 'requesting' });
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const next = { lat: pos.coords.latitude, lng: pos.coords.longitude };
        setGeo(next);
        setGeoStatus({ kind: 'ok' });
        setCenterTrigger({
          lat: next.lat,
          lng: next.lng,
          zoom: 17,
          nonce: Date.now(),
        });
      },
      (err) => {
        // 1 = PERMISSION_DENIED, 2 = POSITION_UNAVAILABLE, 3 = TIMEOUT
        if (err.code === err.PERMISSION_DENIED) {
          setGeoStatus({ kind: 'denied' });
        } else {
          setGeoStatus({
            kind: 'unavailable',
            message: err.message || 'Could not get your location.',
          });
        }
      },
      { enableHighAccuracy: false, timeout: 8_000, maximumAge: 60_000 },
    );
  }, []);

  // Try geolocation on open for users who've already granted permission —
  // resolves silently and pans the map. Users with denied/prompt state get
  // a 'denied' or 'unavailable' status surfaced in the UI + can click the
  // explicit "Use my location" button (which is a user-gesture call —
  // browsers re-prompt on user gestures more reliably than on page-load
  // auto-calls).
  useEffect(() => {
    if (initial) return;
    requestLocation();
  }, [initial, requestLocation]);

  const handleChange = useCallback(
    (next: PolygonGeoJSON | null, nextStats: PolygonStats) => {
      setPolygon(next);
      setStats(nextStats);
    },
    [],
  );

  const handleSave = async () => {
    setError(null);
    const trimmedName = name.trim();
    if (!trimmedName) {
      setError('Name required.');
      return;
    }
    if (trimmedName.length > 80) {
      setError('Name too long (max 80 characters).');
      return;
    }
    if (!polygon || !stats.isValid) {
      if (stats.vertexCount < 3) {
        setError('Add at least 3 vertices to draw the polygon.');
      } else if (stats.areaM2 > 1_000_000) {
        setError('Polygon too large (max 1 km²).');
      } else if (stats.areaM2 < 25) {
        setError('Polygon too small (min 25 m²).');
      } else {
        setError('Polygon is not valid yet.');
      }
      return;
    }

    setSaving(true);
    try {
      const api = createPortalApi(getBrowserClient());
      await api.upsertPremises({
        id: initial?.id ?? null,
        practiceId,
        name: trimmedName,
        address: address.trim().length > 0 ? address.trim() : null,
        polygonGeoJson: JSON.stringify(polygon),
        safeModeEnforced: safeMode,
      });
      onSaved();
    } catch (err) {
      if (err instanceof PremisesError) {
        setError(messageForKind(err));
      } else if (err instanceof Error) {
        setError(err.message);
      } else {
        setError('Save failed. Try again.');
      }
    } finally {
      setSaving(false);
    }
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="premises-editor-title"
      className="fixed inset-0 z-50 flex items-stretch justify-center overflow-y-auto bg-surface-bg/80 px-4 py-8 sm:items-center"
    >
      <div className="w-full max-w-2xl rounded-xl border border-surface-border bg-surface-base p-6 shadow-2xl">
        <div className="mb-4 flex items-start justify-between">
          <h2
            id="premises-editor-title"
            className="font-heading text-xl font-bold"
          >
            {initial ? 'Edit premises' : 'New premises'}
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="text-ink-muted hover:text-ink"
            aria-label="Close"
          >
            ✕
          </button>
        </div>

        <div className="mb-4 flex flex-col gap-3">
          <label className="flex flex-col gap-1 text-sm">
            <span className="font-medium text-ink">Name</span>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              maxLength={80}
              placeholder="Virgin Active Sandton"
              className="rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none"
            />
          </label>
          <label className="flex flex-col gap-1 text-sm">
            <span className="font-medium text-ink">Address (optional)</span>
            <AddressSearchInput
              value={address}
              onChange={setAddress}
              onSelect={(match: AddressMatch) =>
                setCenterTrigger({
                  lat: match.lat,
                  lng: match.lng,
                  zoom: 17,
                  nonce: Date.now(),
                })
              }
            />
          </label>
        </div>

        <div className="mb-2 flex flex-wrap items-center gap-3">
          <button
            type="button"
            onClick={requestLocation}
            disabled={geoStatus.kind === 'requesting'}
            className="inline-flex items-center gap-1.5 rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-xs text-ink hover:border-brand hover:text-brand disabled:opacity-50"
          >
            <span aria-hidden="true">📍</span>
            {geoStatus.kind === 'requesting'
              ? 'Getting location…'
              : geo
                ? 'Re-centre on my location'
                : 'Use my current location'}
          </button>
          {geoStatus.kind === 'denied' && (
            <span className="text-xs text-error">
              Location permission was denied. Reset it in your browser&apos;s
              site settings (lock icon in the address bar → Location → Allow),
              then click the button again.
            </span>
          )}
          {geoStatus.kind === 'unavailable' && (
            <span className="text-xs text-ink-muted">
              {geoStatus.message}
            </span>
          )}
        </div>

        <div className="mb-4">
          <PremisesPolygonEditor
            initial={polygon}
            defaultCenter={
              geo ? { lat: geo.lat, lng: geo.lng, zoom: 17 } : undefined
            }
            onChange={handleChange}
            centerTrigger={centerTrigger}
          />
        </div>

        <label className="mb-4 flex items-start gap-2 text-sm">
          <input
            type="checkbox"
            checked={safeMode}
            onChange={(e) => setSafeMode(e.target.checked)}
            className="mt-1 h-4 w-4 accent-brand"
          />
          <span>
            <span className="font-medium text-ink">Enforce Safe Mode</span>
            <span className="block text-xs text-ink-muted">
              Anyone capturing inside this polygon — including practitioners
              from other practices — will have bystander faces and bodies
              replaced with a coral silhouette in the raw archive. Off means
              the premises is registered (for the directory) but doesn&apos;t
              alter capture.
            </span>
          </span>
        </label>

        {error && (
          <div className="mb-4 rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error">
            {error}
          </div>
        )}

        <div className="flex items-center justify-end gap-3">
          {(() => {
            const reason = disableReason(name, stats);
            if (!reason || saving) return null;
            return (
              <span className="mr-auto text-xs text-ink-muted">{reason}</span>
            );
          })()}
          <button
            type="button"
            onClick={onClose}
            disabled={saving}
            className="rounded-md border border-surface-border px-4 py-2 text-sm text-ink hover:bg-surface-raised disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving || !stats.isValid || name.trim().length === 0}
            className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-50"
          >
            {saving ? 'Saving…' : initial ? 'Save changes' : 'Create premises'}
          </button>
        </div>
      </div>
    </div>
  );
}

// Inline-explains why the Save / Create button is disabled. Returns null
// when the form is ready to submit so the hint disappears. Surfaced
// alongside the button so the user doesn't have to guess.
function disableReason(name: string, stats: PolygonStats): string | null {
  if (name.trim().length === 0) return 'Add a name to enable Save.';
  if (stats.vertexCount < 3) {
    return `Place at least 3 vertices (currently ${stats.vertexCount}).`;
  }
  if (stats.vertexCount > 12) return 'Too many vertices (max 12).';
  if (stats.areaM2 < 25) {
    const rounded = Math.round(stats.areaM2);
    return `Polygon too small (need ≥ 25 m², currently ${rounded} m²).`;
  }
  if (stats.areaM2 > 1_000_000) {
    const km2 = (stats.areaM2 / 1_000_000).toFixed(3);
    return `Polygon too large (max 1 km², currently ${km2} km²).`;
  }
  return null;
}

function messageForKind(err: PremisesError): string {
  switch (err.kind) {
    case 'not-member':
      return 'You don’t have permission on this practice.';
    case 'name-empty':
      return 'Name required.';
    case 'name-too-long':
      return 'Name too long (max 80 characters).';
    case 'invalid-polygon':
      return 'The polygon shape is invalid. Try clearing and redrawing.';
    case 'too-many-vertices':
      return 'Too many vertices (max 12).';
    case 'not-enough-vertices':
      return 'Add at least 3 vertices.';
    case 'polygon-too-large':
      return 'Polygon too large (max 1 km²).';
    case 'polygon-too-small':
      return 'Polygon too small (min 25 m²).';
    case 'not-found':
      return 'Premises not found.';
    default:
      return err.message;
  }
}
