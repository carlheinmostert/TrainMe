'use client';

// Leaflet's stylesheet is imported in web-portal/src/app/globals.css —
// importing here would land in the dynamic(ssr:false) chunk and load
// async after Leaflet's JS runs, leaving tiles unstyled and invisible.
import { useEffect, useMemo, useRef, useState } from 'react';
import type {
  LatLngExpression,
  LeafletMouseEvent,
  Map as LeafletMap,
  Marker as LeafletMarker,
  Polygon as LeafletPolygon,
} from 'leaflet';

/**
 * Leaflet-backed polygon editor for premises boundaries. Click-to-place
 * vertices, drag-to-adjust on existing markers. Max 12 vertices, max
 * 1 km² (enforced server-side; surfaced client-side as a live counter).
 *
 * The editor speaks GeoJSON in and out — the parent owns the polygon
 * state; this component just renders the map + raises onChange.
 *
 * Loaded via `next/dynamic({ ssr: false })` since Leaflet pokes `window`
 * at module load.
 */

type LatLng = { lat: number; lng: number };

export type PolygonGeoJSON = {
  type: 'Polygon';
  coordinates: number[][][];
};

type Props = {
  /** Initial polygon (GeoJSON `Polygon`) to edit. Null to start blank. */
  initial: PolygonGeoJSON | null;
  /** Centre the map here on mount when there's no initial polygon. */
  defaultCenter?: { lat: number; lng: number; zoom?: number };
  /** Raised on every edit; null when the polygon is incomplete (<3 points). */
  onChange: (polygon: PolygonGeoJSON | null, stats: PolygonStats) => void;
  /** Max vertices the user can place. Default 12. */
  maxVertices?: number;
  /** Max area in m². Default 1,000,000 (1 km²). */
  maxAreaM2?: number;
  /**
   * Fly the map to a new centre when this value changes. Use a `nonce`
   * (e.g. `Date.now()`) to re-trigger panning to the same point — the
   * effect keys on object identity, not lat/lng equality.
   */
  centerTrigger?: { lat: number; lng: number; zoom?: number; nonce: number } | null;
};

export type PolygonStats = {
  vertexCount: number;
  /** Approximate area in m² using spherical excess (good enough for ≤ 1 km²). */
  areaM2: number;
  isValid: boolean;
};

const FALLBACK_CENTER = { lat: -33.9249, lng: 18.4241, zoom: 14 };

export function PremisesPolygonEditor({
  initial,
  defaultCenter,
  onChange,
  maxVertices = 12,
  maxAreaM2 = 1_000_000,
  centerTrigger,
}: Props) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const mapRef = useRef<LeafletMap | null>(null);
  const polygonLayerRef = useRef<LeafletPolygon | null>(null);
  const markerLayersRef = useRef<LeafletMarker[]>([]);
  const leafletRef = useRef<typeof import('leaflet') | null>(null);
  const resizeCleanupRef = useRef<(() => void) | null>(null);

  const [vertices, setVertices] = useState<LatLng[]>(() => {
    if (!initial) return [];
    return latLngsFromGeoJson(initial);
  });

  const stats = useMemo(() => computeStats(vertices, maxVertices, maxAreaM2), [vertices, maxVertices, maxAreaM2]);

  // Initialise the map once. Re-using the same instance lets us avoid the
  // "Map container is already initialized" error on hot reload.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const L = await import('leaflet');
      if (cancelled || !containerRef.current || mapRef.current) return;
      leafletRef.current = L;

      const start = vertices.length > 0
        ? centroid(vertices)
        : defaultCenter ?? FALLBACK_CENTER;
      const zoom: number = (defaultCenter?.zoom ?? FALLBACK_CENTER.zoom) ?? 16;

      const map = L.map(containerRef.current, {
        center: [start.lat, start.lng] as LatLngExpression,
        zoom,
        zoomControl: true,
        attributionControl: true,
      });

      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        maxZoom: 19,
        attribution: '© OpenStreetMap contributors',
      }).addTo(map);

      map.on('click', (ev: LeafletMouseEvent) => {
        const next = { lat: ev.latlng.lat, lng: ev.latlng.lng };
        setVertices((prev) => {
          if (prev.length >= maxVertices) return prev;
          return [...prev, next];
        });
      });

      mapRef.current = map;

      // Leaflet caches container dimensions on the first paint. Inside a
      // modal that animates in (or measures 0×0 even briefly), tiles
      // never recompute and the map looks blank under the vertex pins.
      // invalidateSize on the next microtask + on window resize covers
      // both cases.
      requestAnimationFrame(() => {
        if (!cancelled && mapRef.current) mapRef.current.invalidateSize();
      });
      const handleResize = () => {
        if (mapRef.current) mapRef.current.invalidateSize();
      };
      window.addEventListener('resize', handleResize);
      resizeCleanupRef.current = () =>
        window.removeEventListener('resize', handleResize);
    })();
    return () => {
      cancelled = true;
      if (resizeCleanupRef.current) {
        resizeCleanupRef.current();
        resizeCleanupRef.current = null;
      }
      const map = mapRef.current;
      if (map) {
        map.remove();
        mapRef.current = null;
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Sync polygon + draggable vertex markers to the `vertices` state.
  useEffect(() => {
    const L = leafletRef.current;
    const map = mapRef.current;
    if (!L || !map) return;

    if (polygonLayerRef.current) {
      polygonLayerRef.current.remove();
      polygonLayerRef.current = null;
    }
    markerLayersRef.current.forEach((m) => m.remove());
    markerLayersRef.current = [];

    if (vertices.length >= 3) {
      const layer = L.polygon(
        vertices.map((v) => [v.lat, v.lng] as LatLngExpression),
        {
          color: '#FF6B35',
          weight: 2,
          fillColor: '#FF6B35',
          fillOpacity: 0.18,
        },
      );
      layer.addTo(map);
      polygonLayerRef.current = layer;
    } else if (vertices.length === 2) {
      // Show an open polyline for the in-progress shape so the user can
      // see what they've drawn so far.
      const layer = L.polyline(
        vertices.map((v) => [v.lat, v.lng] as LatLngExpression),
        { color: '#FF6B35', weight: 2, dashArray: '4 4' },
      );
      layer.addTo(map);
      polygonLayerRef.current = layer as unknown as LeafletPolygon;
    }

    vertices.forEach((v, idx) => {
      const marker = L.marker([v.lat, v.lng], {
        draggable: true,
        icon: L.divIcon({
          className: 'premises-vertex-marker',
          html: `<div class="premises-vertex-dot" data-idx="${idx + 1}">${idx + 1}</div>`,
          iconSize: [22, 22],
          iconAnchor: [11, 11],
        }),
      });
      marker.on('drag', () => {
        const next = marker.getLatLng();
        setVertices((prev) => prev.map((p, i) => i === idx ? { lat: next.lat, lng: next.lng } : p));
      });
      marker.on('contextmenu', (e: LeafletMouseEvent) => {
        L.DomEvent.stop(e);
        setVertices((prev) => prev.filter((_, i) => i !== idx));
      });
      marker.addTo(map);
      markerLayersRef.current.push(marker);
    });
  }, [vertices]);

  // Pan the map when the address-search picks a result. Keyed on the
  // whole `centerTrigger` reference (nonce included) so the same lat/lng
  // re-triggers panning if the user picks it twice.
  useEffect(() => {
    if (!centerTrigger) return;
    const map = mapRef.current;
    if (!map) return;
    map.flyTo([centerTrigger.lat, centerTrigger.lng], centerTrigger.zoom ?? 17, {
      duration: 0.6,
    });
  }, [centerTrigger]);

  // Raise onChange whenever the polygon settles into a new state.
  useEffect(() => {
    if (vertices.length >= 3) {
      onChange(toGeoJson(vertices), stats);
    } else {
      onChange(null, stats);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vertices, stats.areaM2, stats.vertexCount, stats.isValid]);

  return (
    <div className="flex flex-col gap-3">
      <div
        ref={containerRef}
        className="h-96 w-full overflow-hidden rounded-lg border border-surface-border"
        aria-label="Premises polygon editor"
      />
      <div className="flex items-center justify-between text-xs text-ink-muted">
        <div className="flex flex-wrap gap-3">
          <span>
            Vertices:{' '}
            <span
              className={
                stats.vertexCount > maxVertices ? 'text-error' : 'text-ink'
              }
            >
              {stats.vertexCount} / {maxVertices}
            </span>
          </span>
          <span>
            Area:{' '}
            <span
              className={stats.areaM2 > maxAreaM2 ? 'text-error' : 'text-ink'}
            >
              {fmtArea(stats.areaM2)}
            </span>
          </span>
        </div>
        <div className="flex gap-3">
          <button
            type="button"
            className="text-brand underline decoration-dotted hover:no-underline"
            onClick={() => setVertices([])}
            disabled={vertices.length === 0}
          >
            Clear
          </button>
          <button
            type="button"
            className="text-brand underline decoration-dotted hover:no-underline"
            onClick={() => setVertices((prev) => prev.slice(0, -1))}
            disabled={vertices.length === 0}
          >
            Undo
          </button>
        </div>
      </div>
      <p className="text-xs text-ink-muted">
        Tap the map to place vertices. Drag a vertex pin to move it.
        Right-click a pin to remove it. A polygon needs at least 3 points
        to be saveable.
      </p>
      <style jsx global>{`
        .premises-vertex-marker .premises-vertex-dot {
          background: #ff6b35;
          color: #0f1117;
          border: 2px solid #0f1117;
          border-radius: 9999px;
          width: 22px;
          height: 22px;
          display: flex;
          align-items: center;
          justify-content: center;
          font-size: 11px;
          font-weight: 700;
          line-height: 1;
          font-family: 'Inter', system-ui, sans-serif;
          box-shadow: 0 1px 3px rgba(0, 0, 0, 0.5);
          cursor: grab;
        }
        .premises-vertex-marker .premises-vertex-dot:active {
          cursor: grabbing;
        }
      `}</style>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Geo helpers
// ---------------------------------------------------------------------------

function latLngsFromGeoJson(geo: PolygonGeoJSON): LatLng[] {
  const ring = geo.coordinates?.[0] ?? [];
  // GeoJSON ring is closed (first == last); strip the trailing duplicate.
  const open = ring.length > 0 && coordsEqual(ring[0], ring[ring.length - 1])
    ? ring.slice(0, -1)
    : ring;
  return open.map(([lng, lat]) => ({ lat, lng }));
}

function coordsEqual(a: number[], b: number[]): boolean {
  return Math.abs(a[0] - b[0]) < 1e-9 && Math.abs(a[1] - b[1]) < 1e-9;
}

function toGeoJson(vertices: LatLng[]): PolygonGeoJSON {
  const ring = vertices.map((v) => [v.lng, v.lat]);
  // Close the ring (GeoJSON requires first == last).
  if (ring.length > 0) ring.push([...ring[0]]);
  return {
    type: 'Polygon',
    coordinates: [ring],
  };
}

function centroid(vertices: LatLng[]): { lat: number; lng: number } {
  const sum = vertices.reduce(
    (acc, v) => ({ lat: acc.lat + v.lat, lng: acc.lng + v.lng }),
    { lat: 0, lng: 0 },
  );
  return { lat: sum.lat / vertices.length, lng: sum.lng / vertices.length };
}

function computeStats(
  vertices: LatLng[],
  maxVertices: number,
  maxAreaM2: number,
): PolygonStats {
  if (vertices.length < 3) {
    return { vertexCount: vertices.length, areaM2: 0, isValid: false };
  }
  const area = sphericalPolygonArea(vertices);
  return {
    vertexCount: vertices.length,
    areaM2: area,
    isValid:
      vertices.length <= maxVertices && area <= maxAreaM2 && area >= 25,
  };
}

/**
 * Spherical-excess polygon area (Karney). Accurate for the polygon scales
 * we care about (≤ 1 km²) without needing a full projection library.
 * Source: Mapbox cheap-ruler / Karney 2013.
 */
function sphericalPolygonArea(vertices: LatLng[]): number {
  if (vertices.length < 3) return 0;
  const R = 6_378_137; // WGS84 equatorial radius
  let total = 0;
  for (let i = 0; i < vertices.length; i++) {
    const v1 = vertices[i];
    const v2 = vertices[(i + 1) % vertices.length];
    total +=
      ((v2.lng - v1.lng) * Math.PI) / 180 *
      (2 + Math.sin((v1.lat * Math.PI) / 180) + Math.sin((v2.lat * Math.PI) / 180));
  }
  return Math.abs((total * R * R) / 2);
}

function fmtArea(m2: number): string {
  if (m2 < 10_000) return `${Math.round(m2).toLocaleString()} m²`;
  return `${(m2 / 1_000_000).toFixed(3)} km²`;
}
