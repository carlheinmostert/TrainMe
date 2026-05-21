'use client';

import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Address autocomplete backed by Nominatim (OpenStreetMap's free
 * geocoder). 400ms debounce + AbortController so rapid typing doesn't
 * 429 us under the public 1-req/sec fair-use policy. South Africa-biased
 * via `countrycodes=za` since this is what every practice we have today
 * needs; loosen if we add international practices later.
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

type Result = {
  display_name: string;
  lat: string;
  lon: string;
  place_id: number;
};

type Props = {
  value: string;
  onChange: (value: string) => void;
  onSelect: (match: AddressMatch) => void;
  placeholder?: string;
};

const NOMINATIM_URL = 'https://nominatim.openstreetmap.org/search';
const COUNTRY_BIAS = 'za';
const DEBOUNCE_MS = 400;
const MIN_QUERY = 3;
const LIMIT = 5;

export function AddressSearchInput({
  value,
  onChange,
  onSelect,
  placeholder = 'Search an address — e.g. Virgin Active Sandton',
}: Props) {
  const [results, setResults] = useState<Result[]>([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  // True when the user just picked a result — suppresses the next debounce
  // cycle so we don't re-search the value we just wrote into the field.
  const skipNextSearchRef = useRef(false);

  const runSearch = useCallback(async (query: string) => {
    const trimmed = query.trim();
    if (trimmed.length < MIN_QUERY) {
      setResults([]);
      setOpen(false);
      return;
    }
    if (abortRef.current) abortRef.current.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setLoading(true);
    try {
      const params = new URLSearchParams({
        q: trimmed,
        format: 'json',
        limit: String(LIMIT),
        countrycodes: COUNTRY_BIAS,
        addressdetails: '0',
      });
      const r = await fetch(`${NOMINATIM_URL}?${params.toString()}`, {
        signal: controller.signal,
      });
      if (!r.ok) {
        setResults([]);
        setOpen(false);
        return;
      }
      const json = (await r.json()) as Result[];
      setResults(json);
      setOpen(json.length > 0);
    } catch (err) {
      if ((err as Error).name !== 'AbortError') {
        setResults([]);
        setOpen(false);
      }
    } finally {
      if (abortRef.current === controller) setLoading(false);
    }
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
      lat: parseFloat(r.lat),
      lng: parseFloat(r.lon),
      displayName: r.display_name,
    });
    onChange(r.display_name);
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
          className="absolute left-0 right-0 top-full z-10 mt-1 max-h-64 overflow-y-auto rounded-md border border-surface-border bg-surface-raised shadow-2xl"
        >
          {results.map((r) => (
            <li key={r.place_id} role="option" aria-selected="false">
              <button
                type="button"
                // Prevent input blur firing before the click.
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => handlePick(r)}
                className="block w-full px-3 py-2 text-left text-sm text-ink hover:bg-surface-bg"
              >
                {r.display_name}
              </button>
            </li>
          ))}
        </ul>
      )}
      <p className="mt-1 text-xs text-ink-muted">
        Search powered by{' '}
        <a
          href="https://nominatim.openstreetmap.org/"
          target="_blank"
          rel="noopener noreferrer"
          className="underline decoration-dotted hover:no-underline"
        >
          Nominatim / OpenStreetMap
        </a>
        . Pick a result to pan the map there.
      </p>
    </div>
  );
}
