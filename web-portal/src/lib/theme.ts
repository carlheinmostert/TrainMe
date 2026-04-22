// Brand tokens shared across the portal. Mirror of:
//   app/lib/theme.dart          (Flutter)
//   web-player/styles.css :root  (web player)
// If you change a token here, sync it in the other two surfaces.

export const brand = {
  primary: '#FF6B35',
  primaryDark: '#E85A24',
  primaryLight: '#FF8F5E',
  primarySurface: '#FFF3ED',
} as const;

export const surface = {
  bg: '#0F1117',
  base: '#1A1D27',
  raised: '#242733',
  border: '#2E3140',
} as const;

export const ink = {
  primary: '#F0F0F5',
  muted: '#9CA3AF',
  dim: '#6B7280',
} as const;

export const semantic = {
  ok: '#22C55E',
  warn: '#F59E0B',
  err: '#EF4444',
  rest: '#86EFAC',   // 1.2.0 — sage; mirrors tokens.json color.semantic.rest
} as const;
