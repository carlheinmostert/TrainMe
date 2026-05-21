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
  // Bumped each time the user picks an address-search result so the map
  // pans to the new centre. The `nonce` lets the editor's effect
  // re-trigger even if the user picks the same result twice.
  const [centerTrigger, setCenterTrigger] = useState<
    { lat: number; lng: number; zoom?: number; nonce: number } | null
  >(null);

  // Geolocate on open so the map starts somewhere useful. Failure is fine —
  // the editor falls back to a default centre.
  useEffect(() => {
    if (initial || !('geolocation' in navigator)) return;
    navigator.geolocation.getCurrentPosition(
      (pos) => setGeo({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
      () => {},
      { enableHighAccuracy: false, timeout: 5_000, maximumAge: 60_000 },
    );
  }, [initial]);

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

        <div className="flex justify-end gap-3">
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
