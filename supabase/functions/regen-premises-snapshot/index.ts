// regen-premises-snapshot — Mapbox satellite snapshot for the live view
//
// Invoked by the `regenerate_premises_snapshot(p_premises_id)` RPC via
// pg_net (mirror of the safe-mode-report pattern). Also called from
// `upsert_premises` when a polygon transitions NULL → non-NULL or its
// coordinates change.
//
// Responsibilities:
//   1. Fetch the premises row + polygon coordinates.
//   2. Compute a bounding-box centre + zoom that frames the polygon.
//   3. Call Mapbox Static Images API for a satellite-tile PNG, with the
//      polygon overlaid as a coral outline + soft fill.
//   4. Upload the PNG to `media/premises-snapshots/{practice_id}/{premises_id}.png`.
//   5. Update `practice_premises.snapshot_url` with the public URL.
//
// If `MAPBOX_TOKEN` is missing OR Mapbox returns 5xx, the function
// returns OK with a `degraded: true` marker — the column stays NULL and
// the live page gracefully falls back to the polygon-only SVG.
//
// Spec: docs/specs/2026-05-22-safe-mode-transparency.md + stack items 15-19.

// deno-lint-ignore-file no-explicit-any
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.46.1';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const MAPBOX_TOKEN = Deno.env.get('MAPBOX_TOKEN') ?? '';

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// Output frame dimensions — 4:5 aspect ratio matches the live-page map
// container so the snapshot fills the box without crop. Mapbox max is
// 1280×1280; 640×800 is the right perceptual balance (Retina-crisp,
// quota-friendly).
const FRAME_W = 640;
const FRAME_H = 800;

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return jsonResponse({ ok: true, health: true }, 200);
  }

  let payload: { premises_id?: string; practice_id?: string };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ ok: false, error: 'bad-json' }, 400);
  }

  const premisesId = String(payload.premises_id ?? '');
  if (!premisesId) {
    return jsonResponse({ ok: false, error: 'missing-premises-id' }, 400);
  }

  // No MAPBOX_TOKEN secret → degrade cleanly. Live page handles NULL.
  if (!MAPBOX_TOKEN) {
    return jsonResponse({ ok: true, degraded: true, reason: 'no-mapbox-token' }, 200);
  }

  try {
    const premises = await loadPremises(premisesId);
    if (!premises) {
      return jsonResponse({ ok: false, error: 'premises-not-found' }, 404);
    }

    const coords = extractPolygonCoords(premises.polygon_geojson);
    if (!coords || coords.length < 3) {
      return jsonResponse({ ok: true, degraded: true, reason: 'no-polygon' }, 200);
    }

    const pngBytes = await fetchMapboxSnapshot(coords);
    if (!pngBytes) {
      return jsonResponse({ ok: true, degraded: true, reason: 'mapbox-error' }, 200);
    }

    const path = `premises-snapshots/${premises.practice_id}/${premises.id}.png`;
    const uploaded = await uploadSnapshot(path, pngBytes);
    if (!uploaded) {
      return jsonResponse({ ok: false, error: 'upload-failed' }, 500);
    }

    const publicUrl = `${SUPABASE_URL}/storage/v1/object/public/media/${path}?v=${Date.now()}`;
    const { error } = await admin
      .from('practice_premises')
      .update({ snapshot_url: publicUrl })
      .eq('id', premises.id);

    if (error) {
      return jsonResponse({ ok: false, error: 'column-update-failed', detail: error.message }, 500);
    }

    return jsonResponse({ ok: true, snapshot_url: publicUrl }, 200);
  } catch (err) {
    console.error('regen-premises-snapshot error', err);
    return jsonResponse({ ok: false, error: 'unhandled', detail: String(err) }, 500);
  }
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function loadPremises(id: string): Promise<
  { id: string; practice_id: string; polygon_geojson: string } | null
> {
  // `get_premises` requires auth.uid() (membership check); service-role
  // calls have no uid, so we use a small dedicated RPC that bypasses the
  // membership gate for service-role only. Until that lands, use a
  // direct REST query through the admin client — RLS is bypassed by
  // the service-role JWT.
  //
  // We need the polygon as GeoJSON, but the PostgREST raw column is the
  // geometry binary. Use a SECURITY DEFINER helper to convert.
  const { data, error } = await admin.rpc('get_premises_for_snapshot', {
    p_premises_id: id,
  });
  if (error || !data) {
    console.error('loadPremises rpc error', error);
    return null;
  }
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return null;
  return {
    id: String(row.id),
    practice_id: String(row.practice_id),
    polygon_geojson: typeof row.polygon_geojson === 'string'
      ? row.polygon_geojson
      : '',
  };
}

function extractPolygonCoords(polygonGeoJson: string): Array<[number, number]> | null {
  try {
    const obj = typeof polygonGeoJson === 'string'
      ? JSON.parse(polygonGeoJson)
      : polygonGeoJson;
    if (!obj || obj.type !== 'Polygon') return null;
    const ring = (obj.coordinates ?? [])[0];
    if (!Array.isArray(ring) || ring.length < 3) return null;
    // GeoJSON ring order: [lng, lat]. We pass through unchanged — Mapbox
    // also expects [lng, lat].
    return ring
      .filter((pt: any) => Array.isArray(pt) && Number.isFinite(pt[0]) && Number.isFinite(pt[1]))
      .map((pt: any) => [Number(pt[0]), Number(pt[1])] as [number, number]);
  } catch {
    return null;
  }
}

async function fetchMapboxSnapshot(
  coords: Array<[number, number]>,
): Promise<Uint8Array | null> {
  // Mapbox Static Images API with a GeoJSON overlay. The overlay
  // serialises the polygon as a path; the API auto-fits the camera to
  // it when we use `auto` for the camera params.
  //
  // Path encoding: pin-l-X+RGB(lng,lat) for points, or `path-{stroke
  // width}+{hex}-{opacity}+{fill}-{opacity}({encoded polyline})` for
  // lines. Here we use the GeoJSON overlay form — simpler for polygons.
  const geojsonOverlay = {
    type: 'Feature',
    properties: {
      stroke: '#FF6B35',
      'stroke-width': 3,
      'stroke-opacity': 0.95,
      fill: '#FF6B35',
      'fill-opacity': 0.15,
    },
    geometry: {
      type: 'Polygon',
      coordinates: [coords.concat([coords[0]])], // close ring if needed
    },
  };
  const encoded = encodeURIComponent(JSON.stringify(geojsonOverlay));

  // `auto` lets Mapbox pick the best camera framing for the overlay.
  // The pipe-separator pattern follows Mapbox's documented spec.
  const url =
    `https://api.mapbox.com/styles/v1/mapbox/satellite-streets-v12/static/` +
    `geojson(${encoded})/auto/${FRAME_W}x${FRAME_H}@2x` +
    `?access_token=${MAPBOX_TOKEN}&padding=40&attribution=false&logo=false`;

  try {
    const resp = await fetch(url);
    if (!resp.ok) {
      console.error('Mapbox status', resp.status, await resp.text().catch(() => ''));
      return null;
    }
    const buf = new Uint8Array(await resp.arrayBuffer());
    return buf;
  } catch (err) {
    console.error('Mapbox fetch failed', err);
    return null;
  }
}

async function uploadSnapshot(path: string, bytes: Uint8Array): Promise<boolean> {
  const { error } = await admin.storage.from('media').upload(path, bytes, {
    contentType: 'image/png',
    upsert: true,
    cacheControl: '3600',
  });
  if (error) {
    console.error('Snapshot upload failed', error);
    return false;
  }
  return true;
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
