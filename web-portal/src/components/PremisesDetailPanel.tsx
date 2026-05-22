'use client';

import { useCallback, useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import dynamic from 'next/dynamic';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  PremisesError,
  type PracticePremises,
} from '@/lib/supabase/api';
import { AddressSearchInput, type AddressMatch } from './AddressSearchInput';
import type { PolygonGeoJSON, PolygonStats } from './PremisesPolygonEditor';

// Leaflet writes to `window` at import time, so the editor must be
// SSR-skipped just like the old dialog had it.
const PremisesPolygonEditor = dynamic(
  () =>
    import('./PremisesPolygonEditor').then((m) => m.PremisesPolygonEditor),
  {
    ssr: false,
    loading: () => (
      <div className="h-96 w-full animate-pulse rounded-lg border border-surface-border bg-surface-base" />
    ),
  },
);

type FieldSaveState =
  | { kind: 'idle' }
  | { kind: 'saving' }
  | { kind: 'ok' }
  | { kind: 'err'; message: string };

type Props = {
  initial: PracticePremises;
  practiceId: string;
};

/**
 * Full-page detail / editor for a single premises. Inline-edits for
 * name + address + Safe Mode (each field autosaves on blur via
 * `update_premises_metadata`); polygon is a deliberate multi-step
 * interaction with an explicit "Save polygon" button (kept as a
 * separate save semantics from autosave because drawing 3+ vertices
 * + tweaking is not idempotent on each motion).
 *
 * Replaces the old modal-dialog flow (R-01 + no-popups-ever).
 */
export function PremisesDetailPanel({ initial, practiceId }: Props) {
  const router = useRouter();
  const api = useCallback(() => createPortalApi(getBrowserClient()), []);

  // ---------------------------------------------------------------------
  // Name (inline dashed-underline — mirrors PracticeNameField pattern)
  // ---------------------------------------------------------------------
  const [name, setName] = useState(initial.name);
  const [editingName, setEditingName] = useState(false);
  const [nameDraft, setNameDraft] = useState(initial.name);
  const [namePending, startNameSave] = useTransition();
  const [nameState, setNameState] = useState<FieldSaveState>({ kind: 'idle' });
  const nameInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (editingName && nameInputRef.current) {
      nameInputRef.current.focus();
      nameInputRef.current.select();
    }
  }, [editingName]);

  useEffect(() => {
    if (nameState.kind === 'idle' || nameState.kind === 'saving') return;
    const ttl = nameState.kind === 'err' ? 4000 : 2000;
    const id = window.setTimeout(() => setNameState({ kind: 'idle' }), ttl);
    return () => window.clearTimeout(id);
  }, [nameState]);

  function startNameEditing() {
    setNameDraft(name);
    setNameState({ kind: 'idle' });
    setEditingName(true);
  }

  function cancelNameEdit() {
    setNameDraft(name);
    setEditingName(false);
  }

  function commitName() {
    const trimmed = nameDraft.trim();
    if (trimmed === name) {
      setEditingName(false);
      return;
    }
    if (trimmed === '') {
      setNameState({ kind: 'err', message: "Name can't be empty." });
      return;
    }
    startNameSave(async () => {
      try {
        await api().updatePremisesMetadata({
          premisesId: initial.id,
          name: trimmed,
        });
        setName(trimmed);
        setEditingName(false);
        setNameState({ kind: 'ok' });
        router.refresh();
      } catch (e) {
        setNameState({ kind: 'err', message: mapErr(e, 'rename') });
      }
    });
  }

  // ---------------------------------------------------------------------
  // Address (inline text + AddressSearchInput; autosave on blur)
  // ---------------------------------------------------------------------
  const [address, setAddress] = useState(initial.address ?? '');
  const [addressState, setAddressState] = useState<FieldSaveState>({ kind: 'idle' });
  const addressBaseline = useRef(initial.address ?? '');

  useEffect(() => {
    if (addressState.kind === 'idle' || addressState.kind === 'saving') return;
    const ttl = addressState.kind === 'err' ? 4000 : 2000;
    const id = window.setTimeout(() => setAddressState({ kind: 'idle' }), ttl);
    return () => window.clearTimeout(id);
  }, [addressState]);

  async function commitAddress() {
    if (address.trim() === addressBaseline.current.trim()) return;
    setAddressState({ kind: 'saving' });
    try {
      await api().updatePremisesMetadata({
        premisesId: initial.id,
        address: address.trim(),
      });
      addressBaseline.current = address.trim();
      setAddressState({ kind: 'ok' });
      router.refresh();
    } catch (e) {
      setAddressState({ kind: 'err', message: mapErr(e, 'save address') });
    }
  }

  // ---------------------------------------------------------------------
  // Safe Mode (toggle; autosaves on change)
  // ---------------------------------------------------------------------
  const [safeMode, setSafeMode] = useState(initial.safeModeEnforced);
  const [safeModeState, setSafeModeState] = useState<FieldSaveState>({ kind: 'idle' });

  useEffect(() => {
    if (safeModeState.kind === 'idle' || safeModeState.kind === 'saving') return;
    const ttl = safeModeState.kind === 'err' ? 4000 : 2000;
    const id = window.setTimeout(
      () => setSafeModeState({ kind: 'idle' }),
      ttl,
    );
    return () => window.clearTimeout(id);
  }, [safeModeState]);

  async function toggleSafeMode(next: boolean) {
    const prev = safeMode;
    setSafeMode(next);
    setSafeModeState({ kind: 'saving' });
    try {
      await api().updatePremisesMetadata({
        premisesId: initial.id,
        safeModeEnforced: next,
      });
      setSafeModeState({ kind: 'ok' });
      router.refresh();
    } catch (e) {
      // Rollback on failure.
      setSafeMode(prev);
      setSafeModeState({ kind: 'err', message: mapErr(e, 'save Safe Mode') });
    }
  }

  // ---------------------------------------------------------------------
  // Polygon (deliberate save via "Save polygon" button)
  // ---------------------------------------------------------------------
  const [polygon, setPolygon] = useState<PolygonGeoJSON | null>(() => {
    if (!initial.polygonGeoJson) return null;
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
  const [polygonState, setPolygonState] = useState<FieldSaveState>({ kind: 'idle' });
  // Initialised once on mount based on whether the row already has a
  // polygon. Subsequent edits flip back to "dirty" via the onChange.
  const [polygonDirty, setPolygonDirty] = useState(false);

  // Geolocation (used both for centring the editor on first paint and
  // as the explicit "Use my location" button — same pattern as the old
  // dialog).
  const [geo, setGeo] = useState<{ lat: number; lng: number } | null>(() => {
    if (initial.centroidLat != null && initial.centroidLng != null) {
      return { lat: initial.centroidLat, lng: initial.centroidLng };
    }
    return null;
  });
  type GeoStatus =
    | { kind: 'idle' }
    | { kind: 'requesting' }
    | { kind: 'ok' }
    | { kind: 'denied' }
    | { kind: 'unavailable'; message: string };
  const [geoStatus, setGeoStatus] = useState<GeoStatus>({ kind: 'idle' });
  const [centerTrigger, setCenterTrigger] = useState<
    { lat: number; lng: number; zoom?: number; nonce: number } | null
  >(null);

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

  // Auto-attempt geolocation on draft rows where we have nothing to
  // recentre on. Existing rows already have a centroid from the polygon.
  useEffect(() => {
    if (initial.polygonGeoJson) return;
    requestLocation();
  }, [initial.polygonGeoJson, requestLocation]);

  const handlePolygonChange = useCallback(
    (next: PolygonGeoJSON | null, nextStats: PolygonStats) => {
      setPolygon(next);
      setStats(nextStats);
      setPolygonDirty(true);
    },
    [],
  );

  async function savePolygon() {
    if (!polygon || !stats.isValid) {
      let msg = 'Polygon is not valid yet.';
      if (stats.vertexCount < 3) msg = 'Add at least 3 vertices.';
      else if (stats.areaM2 > 1_000_000) msg = 'Polygon too large (max 1 km²).';
      else if (stats.areaM2 < 25) msg = 'Polygon too small (min 25 m²).';
      setPolygonState({ kind: 'err', message: msg });
      return;
    }
    setPolygonState({ kind: 'saving' });
    try {
      await api().upsertPremises({
        id: initial.id,
        practiceId,
        name: name.trim(),
        address: address.trim().length > 0 ? address.trim() : null,
        polygonGeoJson: JSON.stringify(polygon),
        safeModeEnforced: safeMode,
      });
      setPolygonDirty(false);
      setPolygonState({ kind: 'ok' });
      router.refresh();
    } catch (e) {
      setPolygonState({
        kind: 'err',
        message:
          e instanceof PremisesError
            ? messageForPremisesError(e)
            : e instanceof Error
              ? e.message
              : 'Save failed. Try again.',
      });
    }
  }

  useEffect(() => {
    if (polygonState.kind === 'idle' || polygonState.kind === 'saving') return;
    const ttl = polygonState.kind === 'err' ? 5000 : 2500;
    const id = window.setTimeout(
      () => setPolygonState({ kind: 'idle' }),
      ttl,
    );
    return () => window.clearTimeout(id);
  }, [polygonState]);

  const isDraft = !initial.polygonGeoJson;

  return (
    <div className="flex flex-col gap-6">
      {/* Header: name (inline) + status chip */}
      <section className="rounded-xl border border-surface-border bg-surface-base p-6">
        <div className="flex flex-col gap-2">
          {!editingName ? (
            <div className="flex flex-wrap items-center gap-3">
              <span
                role="button"
                tabIndex={0}
                onClick={startNameEditing}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    startNameEditing();
                  }
                }}
                title="Click to rename"
                className="inline-block cursor-text border-b border-dashed border-ink-muted font-heading text-2xl font-bold text-ink transition hover:border-brand focus-visible:border-brand focus-visible:outline-none"
              >
                {name}
              </span>
              {isDraft ? (
                <span className="rounded-full border border-dashed border-surface-border px-2 py-0.5 text-xs text-ink-muted">
                  Draft - draw a polygon below to finish
                </span>
              ) : safeMode ? (
                <span className="rounded-full bg-brand/15 px-2 py-0.5 text-xs font-medium text-brand">
                  Safe Mode on
                </span>
              ) : (
                <span className="rounded-full border border-surface-border px-2 py-0.5 text-xs text-ink-muted">
                  Registered only
                </span>
              )}
            </div>
          ) : (
            <div className="flex flex-col gap-2">
              <label htmlFor="premises-name-input" className="sr-only">
                Premises name
              </label>
              <input
                ref={nameInputRef}
                id="premises-name-input"
                type="text"
                value={nameDraft}
                onChange={(e) => {
                  setNameDraft(e.target.value);
                  if (nameState.kind !== 'idle' && nameState.kind !== 'saving') {
                    setNameState({ kind: 'idle' });
                  }
                }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault();
                    commitName();
                  } else if (e.key === 'Escape') {
                    e.preventDefault();
                    cancelNameEdit();
                  }
                }}
                onBlur={() => {
                  if (!namePending) commitName();
                }}
                disabled={namePending}
                maxLength={80}
                aria-invalid={nameState.kind === 'err'}
                className={`max-w-md rounded-md border bg-surface-base px-3 py-2 font-heading text-2xl font-bold text-ink focus:outline-none disabled:opacity-60 ${
                  nameState.kind === 'err'
                    ? 'border-error focus:border-error'
                    : 'border-brand focus:border-brand'
                }`}
              />
              <p className="text-xs text-ink-dim">
                Enter to save - Esc to cancel - max 80 characters
              </p>
            </div>
          )}
          {nameState.kind === 'ok' && (
            <p role="status" className="text-xs text-success">
              Renamed.
            </p>
          )}
          {nameState.kind === 'err' && (
            <p
              role="alert"
              className="rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error"
            >
              {nameState.message}
            </p>
          )}
        </div>
      </section>

      {/* Address + Safe Mode (inline) */}
      <section className="rounded-xl border border-surface-border bg-surface-base p-6">
        <div className="flex flex-col gap-5">
          <div className="flex flex-col gap-1.5">
            <label
              htmlFor="premises-address-input"
              className="text-sm font-medium text-ink"
            >
              Address
              <span className="ml-1 text-xs font-normal text-ink-muted">
                (optional)
              </span>
            </label>
            <AddressSearchInput
              value={address}
              onChange={setAddress}
              onSelect={(match: AddressMatch) => {
                // Fly the map to the chosen address. Save the text on
                // selection too so the user doesn't have to blur first.
                setCenterTrigger({
                  lat: match.lat,
                  lng: match.lng,
                  zoom: 17,
                  nonce: Date.now(),
                });
              }}
            />
            <div className="flex items-center justify-between">
              <p className="text-xs text-ink-muted">
                Helps you find this site again. Saved on blur.
              </p>
              <button
                type="button"
                onClick={commitAddress}
                disabled={addressState.kind === 'saving'}
                className="rounded-md border border-surface-border px-2 py-1 text-xs text-ink-muted hover:border-brand hover:text-brand disabled:opacity-50"
              >
                {addressState.kind === 'saving' ? 'Saving...' : 'Save'}
              </button>
            </div>
            {addressState.kind === 'ok' && (
              <p role="status" className="text-xs text-success">
                Address saved.
              </p>
            )}
            {addressState.kind === 'err' && (
              <p
                role="alert"
                className="rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error"
              >
                {addressState.message}
              </p>
            )}
          </div>

          <label className="flex items-start gap-3 text-sm">
            <input
              type="checkbox"
              checked={safeMode}
              onChange={(e) => toggleSafeMode(e.target.checked)}
              disabled={safeModeState.kind === 'saving'}
              className="mt-1 h-4 w-4 accent-brand"
            />
            <span>
              <span className="font-medium text-ink">Enforce Safe Mode</span>
              <span className="block text-xs text-ink-muted">
                Anyone capturing inside this polygon - including practitioners
                from other practices - will have bystander faces and bodies
                replaced with a coral silhouette in the raw archive. Off means
                the premises is registered (for the directory) but doesn&apos;t
                alter capture.
              </span>
            </span>
          </label>
          {safeModeState.kind === 'ok' && (
            <p role="status" className="text-xs text-success">
              Safe Mode setting saved.
            </p>
          )}
          {safeModeState.kind === 'err' && (
            <p
              role="alert"
              className="rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error"
            >
              {safeModeState.message}
            </p>
          )}
        </div>
      </section>

      {/* Polygon editor (deliberate save) */}
      <section className="rounded-xl border border-surface-border bg-surface-base p-6">
        <div className="mb-3 flex flex-col gap-1">
          <h2 className="font-heading text-lg font-semibold">Boundary</h2>
          <p className="text-xs text-ink-muted">
            Draw the polygon that anchors Safe Mode. Click to place vertices,
            drag markers to adjust. 3-12 vertices, 25 m² - 1 km².
          </p>
        </div>

        <div className="mb-2 flex flex-wrap items-center gap-3">
          <button
            type="button"
            onClick={requestLocation}
            disabled={geoStatus.kind === 'requesting'}
            className="rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-xs text-ink hover:border-brand hover:text-brand disabled:opacity-50"
          >
            {geoStatus.kind === 'requesting'
              ? 'Getting location...'
              : geo
                ? 'Re-centre on my location'
                : 'Use my current location'}
          </button>
          {geoStatus.kind === 'denied' && (
            <span className="text-xs text-error">
              Location permission was denied. Reset it in your browser&apos;s
              site settings, then click the button again.
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
            onChange={handlePolygonChange}
            centerTrigger={centerTrigger}
          />
        </div>

        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="text-xs text-ink-muted">
            {disableReason(stats) ?? 'Polygon ready to save.'}
          </div>
          <div className="flex items-center gap-2">
            {polygonState.kind === 'ok' && (
              <span role="status" className="text-xs text-success">
                Polygon saved.
              </span>
            )}
            <button
              type="button"
              onClick={savePolygon}
              disabled={
                polygonState.kind === 'saving' ||
                !stats.isValid ||
                !polygonDirty
              }
              className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-50"
            >
              {polygonState.kind === 'saving' ? 'Saving...' : 'Save polygon'}
            </button>
          </div>
        </div>

        {polygonState.kind === 'err' && (
          <p
            role="alert"
            className="mt-3 rounded-md border border-error/40 bg-error/10 px-3 py-2 text-sm text-error"
          >
            {polygonState.message}
          </p>
        )}
      </section>
    </div>
  );
}

// Mirrors the old dialog's hint logic so the practitioner gets the
// same "why can't I save?" feedback inline.
function disableReason(stats: PolygonStats): string | null {
  if (stats.vertexCount === 0) {
    return 'Click the map to place your first vertex.';
  }
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

function messageForPremisesError(err: PremisesError): string {
  switch (err.kind) {
    case 'not-member':
      return "You don't have permission on this practice.";
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

function mapErr(e: unknown, verb: string): string {
  if (e instanceof PremisesError) return messageForPremisesError(e);
  if (e instanceof Error) return `Couldn't ${verb} - ${e.message}`;
  return `Couldn't ${verb}.`;
}
