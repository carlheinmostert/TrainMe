'use client';

import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Address autocomplete backed by Nominatim (OpenStreetMap's free
 * geocoder). 400ms debounce + AbortController so rapid typing doesn't
 * 429 us under the public 1-req/sec fair-use policy.
 *
 * No hard country filter — `countrycodes=za` was too aggressive: Carl
 * could find his real ZA home address on the OpenStreetMap website but
 * Nominatim's API silently dropped it from results because of how that
 * address's country attribution is indexed. `display_name` includes the
 * country so the user can disambiguate which result they want.
 *
 * Browsers forbid setting User-Agent on fetch, so identification falls
 * back to the page's Referer header + the inherently low call volume
 * from a manual entry form. If Nominatim ever rate-limits us, the next
 * step is a tiny Next.js route-handler proxy that adds the User-Agent
 * server-side.
 */

export type AddressMatch = {
  lat: number;
  lng: number;
  displayName: string;
};

type Source = 'nominatim' | 'photon';

type Result = {
  source: Source;
  displayName: string;
  lat: number;
  lng: number;
  // Stable identity per source for React keys + dedupe across providers.
  key: string;
};

type Props = {
  value: string;
  onChange: (value: string) => void;
  onSelect: (match: AddressMatch) => void;
  placeholder?: string;
};

const NOMINATIM_URL = 'https://nominatim.openstreetmap.org/search';
const PHOTON_URL = 'https://photon.komoot.io/api/';
const DEBOUNCE_MS = 400;
const MIN_QUERY = 3;
const LIMIT = 8;
// Two coordinates are "the same place" if within ~50 metres at this latitude
// (0.0005° ≈ 55 m). Used to dedupe when Nominatim + Photon both return the
// same hit.
const DEDUPE_DEG = 0.0005;

export function AddressSearchInput({
  value,
  onChange,
  onSelect,
  placeholder = 'Search an address — e.g. Virgin Active Sandton',
}: Props) {
  const [results, setResults] = useState<Result[]>([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  // Visible diagnostic state so failures are obvious without DevTools.
  // Kinds: 'idle' (typing nothing yet), 'too-short' (under MIN_QUERY chars),
  // 'searching', 'no-results' (Nominatim returned 0 matches),
  // 'error' (fetch threw or non-2xx), 'ok' (≥1 result).
  type SearchStatus =
    | { kind: 'idle' }
    | { kind: 'too-short' }
    | { kind: 'searching' }
    | { kind: 'no-results' }
    | { kind: 'error'; message: string }
    | { kind: 'ok'; count: number };
  const [status, setStatus] = useState<SearchStatus>({ kind: 'idle' });
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  // True when the user just picked a result — suppresses the next debounce
  // cycle so we don't re-search the value we just wrote into the field.
  const skipNextSearchRef = useRef(false);

  const runSearch = useCallback(async (query: string) => {
    const trimmed = query.trim();
    if (trimmed.length === 0) {
      setResults([]);
      setOpen(false);
      setStatus({ kind: 'idle' });
      return;
    }
    if (trimmed.length < MIN_QUERY) {
      setResults([]);
      setOpen(false);
      setStatus({ kind: 'too-short' });
      return;
    }
    if (abortRef.current) abortRef.current.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setLoading(true);
    setStatus({ kind: 'searching' });

    // Fire BOTH geocoders in parallel. Nominatim is strict full-text;
    // Photon (komoot's OSM-based geocoder) has better fuzzy matching and
    // address-tokenisation. OSM's own website uses Photon for the
    // autocomplete dropdown — addresses that "show on osm.org but not
    // via the Nominatim API" usually surface in Photon.
    const [nominatimResults, photonResults] = await Promise.all([
      fetchNominatim(trimmed, controller.signal),
      fetchPhoton(trimmed, controller.signal),
    ]);

    if (controller.signal.aborted) return;

    // If both failed, surface error. If one failed, we still show the
    // other's results — Photon stays valuable when Nominatim 429s and
    // vice versa.
    if (nominatimResults.kind === 'error' && photonResults.kind === 'error') {
      setResults([]);
      setOpen(false);
      setStatus({
        kind: 'error',
        message: `Both geocoders failed (${nominatimResults.message}; ${photonResults.message})`,
      });
      if (abortRef.current === controller) setLoading(false);
      return;
    }

    const combined: Result[] = [
      ...(nominatimResults.kind === 'ok' ? nominatimResults.results : []),
      ...(photonResults.kind === 'ok' ? photonResults.results : []),
    ];
    const deduped = dedupeByLatLng(combined).slice(0, LIMIT);

    // eslint-disable-next-line no-console
    console.debug(
      '[Geocoder] combined',
      `nominatim=${nominatimResults.kind === 'ok' ? nominatimResults.results.length : 'err'}`,
      `photon=${photonResults.kind === 'ok' ? photonResults.results.length : 'err'}`,
      `→ ${deduped.length} after dedupe`,
    );

    setResults(deduped);
    setOpen(deduped.length > 0);
    setStatus(
      deduped.length > 0
        ? { kind: 'ok', count: deduped.length }
        : { kind: 'no-results' },
    );
    if (abortRef.current === controller) setLoading(false);
  }, []);

  useEffect(() => {
    if (skipNextSearchRef.current) {
      skipNextSearchRef.current = false;
      return;
    }
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => runSearch(value), DEBOUNCE_MS);
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [value, runSearch]);

  const handlePick = (r: Result) => {
    skipNextSearchRef.current = true;
    onSelect({
      lat: r.lat,
      lng: r.lng,
      displayName: r.displayName,
    });
    onChange(r.displayName);
    setOpen(false);
  };

  return (
    <div className="relative">
      <input
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onFocus={() => results.length > 0 && setOpen(true)}
        // Delay blur so the click on a result button registers first.
        onBlur={() => setTimeout(() => setOpen(false), 150)}
        placeholder={placeholder}
        className="w-full rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none"
        aria-autocomplete="list"
        aria-expanded={open}
      />
      {loading && (
        <div
          className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-xs text-ink-muted"
          aria-hidden="true"
        >
          …
        </div>
      )}
      {open && results.length > 0 && (
        <ul
          role="listbox"
          // z-50 lifts above Leaflet panes (which use z-index 400+ inside
          // their map container; same stacking context inside the dialog).
          className="absolute left-0 right-0 top-full z-50 mt-1 max-h-64 overflow-y-auto rounded-md border border-surface-border bg-surface-raised shadow-2xl"
        >
          {results.map((r) => (
            <li key={r.key} role="option" aria-selected="false">
              <button
                type="button"
                // Prevent input blur firing before the click.
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => handlePick(r)}
                className="block w-full px-3 py-2 text-left text-sm text-ink hover:bg-surface-bg"
              >
                <span>{r.displayName}</span>
                <span className="ml-2 text-[10px] uppercase tracking-wide text-ink-muted">
                  {r.source}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {/* Visible status — surfaces "no results", "searching", and error
          conditions on-screen so failures don't require DevTools. */}
      {status.kind === 'searching' && (
        <p className="mt-1 text-xs text-ink-muted">Searching…</p>
      )}
      {status.kind === 'no-results' && (
        <p className="mt-1 text-xs text-ink-muted">
          No matches. Try a different spelling (street + suburb works better
          than full address), or place the polygon manually on the map.
        </p>
      )}
      {status.kind === 'error' && (
        <p className="mt-1 text-xs text-error">
          {status.message}. Check DevTools → Network for the failing request.
        </p>
      )}
      {status.kind === 'too-short' && (
        <p className="mt-1 text-xs text-ink-muted">
          Keep typing ({MIN_QUERY}+ characters to search).
        </p>
      )}
      <p className="mt-1 text-xs text-ink-muted">
        Search powered by{' '}
        <a
          href="https://nominatim.openstreetmap.org/"
          target="_blank"
          rel="noopener noreferrer"
          className="underline decoration-dotted hover:no-underline"
        >
          Nominatim
        </a>{' '}
        +{' '}
        <a
          href="https://photon.komoot.io/"
          target="_blank"
          rel="noopener noreferrer"
          className="underline decoration-dotted hover:no-underline"
        >
          Photon
        </a>
        . Pick a result to pan the map.
      </p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Geocoder fetches
// ---------------------------------------------------------------------------

type FetchResult =
  | { kind: 'ok'; results: Result[] }
  | { kind: 'error'; message: string };

async function fetchNominatim(
  query: string,
  signal: AbortSignal,
): Promise<FetchResult> {
  const params = new URLSearchParams({
    q: query,
    format: 'json',
    limit: String(LIMIT),
    addressdetails: '0',
  });
  const url = `${NOMINATIM_URL}?${params.toString()}`;
  // eslint-disable-next-line no-console
  console.debug('[Nominatim] →', url);
  try {
    const r = await fetch(url, { signal });
    if (!r.ok) {
      // eslint-disable-next-line no-console
      console.warn('[Nominatim] non-2xx', r.status);
      return { kind: 'error', message: `Nominatim ${r.status}` };
    }
    const json = (await r.json()) as Array<{
      display_name: string;
      lat: string;
      lon: string;
      place_id: number;
    }>;
    // eslint-disable-next-line no-console
    console.debug('[Nominatim] ←', json.length, 'result(s)');
    return {
      kind: 'ok',
      results: json.map((j) => ({
        source: 'nominatim' as const,
        displayName: j.display_name,
        lat: parseFloat(j.lat),
        lng: parseFloat(j.lon),
        key: `n-${j.place_id}`,
      })),
    };
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      return { kind: 'ok', results: [] };
    }
    // eslint-disable-next-line no-console
    console.error('[Nominatim] fetch failed', err);
    return {
      kind: 'error',
      message: err instanceof Error ? err.message : 'Nominatim unreachable',
    };
  }
}

async function fetchPhoton(
  query: string,
  signal: AbortSignal,
): Promise<FetchResult> {
  const params = new URLSearchParams({
    q: query,
    limit: String(LIMIT),
  });
  const url = `${PHOTON_URL}?${params.toString()}`;
  // eslint-disable-next-line no-console
  console.debug('[Photon] →', url);
  try {
    const r = await fetch(url, { signal });
    if (!r.ok) {
      // eslint-disable-next-line no-console
      console.warn('[Photon] non-2xx', r.status);
      return { kind: 'error', message: `Photon ${r.status}` };
    }
    const json = (await r.json()) as {
      features?: Array<{
        properties?: {
          name?: string;
          street?: string;
          housenumber?: string;
          city?: string;
          state?: string;
          country?: string;
          postcode?: string;
          osm_id?: number | string;
        };
        geometry?: { coordinates?: [number, number] };
      }>;
    };
    const features = json.features ?? [];
    // eslint-disable-next-line no-console
    console.debug('[Photon] ←', features.length, 'result(s)');
    return {
      kind: 'ok',
      results: features
        .filter((f) => Array.isArray(f.geometry?.coordinates))
        .map((f, i) => {
          const p = f.properties ?? {};
          const coords = f.geometry!.coordinates!;
          // Photon returns [lng, lat] (GeoJSON order).
          const [lng, lat] = coords;
          const parts = [
            p.housenumber ? `${p.housenumber} ${p.street ?? ''}`.trim() : p.street,
            p.name && p.name !== p.street ? p.name : undefined,
            p.city,
            p.state,
            p.postcode,
            p.country,
          ].filter((s): s is string => Boolean(s));
          const displayName = parts.join(', ') || p.name || 'Unnamed place';
          return {
            source: 'photon' as const,
            displayName,
            lat,
            lng,
            key: `p-${p.osm_id ?? i}-${lat.toFixed(5)}-${lng.toFixed(5)}`,
          };
        }),
    };
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      return { kind: 'ok', results: [] };
    }
    // eslint-disable-next-line no-console
    console.error('[Photon] fetch failed', err);
    return {
      kind: 'error',
      message: err instanceof Error ? err.message : 'Photon unreachable',
    };
  }
}

// Two candidates within ~50m collapse to one. We keep the FIRST occurrence
// in the iteration order — since the combined array is [...nominatim,
// ...photon], Nominatim wins ties, which preserves stable behaviour for
// users who've been using the search since PR #390.
function dedupeByLatLng(results: Result[]): Result[] {
  const out: Result[] = [];
  for (const r of results) {
    const dup = out.some(
      (o) =>
        Math.abs(o.lat - r.lat) < DEDUPE_DEG &&
        Math.abs(o.lng - r.lng) < DEDUPE_DEG,
    );
    if (!dup) out.push(r);
  }
  return out;
}
