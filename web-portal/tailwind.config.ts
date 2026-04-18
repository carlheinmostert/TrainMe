import type { Config } from 'tailwindcss';

// Brand tokens mirror app/lib/theme.dart and web-player/styles.css :root.
// Single source of truth: docs/design/project/tokens.json.
// Decisions applied: D-03, D-04, D-05, D-07, D-09, D-10.
//
// D-05 note: Tailwind's default spacing scale uses `rem` (1rem = 16px by
// default), so `p-1` → 4px, `p-2` → 8px, `p-3` → 12px, `p-4` → 16px, etc.
// That happens to match the approved 4/8/12/16/20/24/32/40/48/64 scale
// at the baseline font size. We intentionally do NOT override the default
// spacing — keeping rem-based units preserves user-zoom accessibility.
//
// D-06 note: canonical Empty/Loading/Error/Success/Disabled state treatments
// are a per-screen refactor. Apply incrementally as screens are touched —
// see docs/design/project/components.md.
const config: Config = {
  content: ['./src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          DEFAULT: '#FF6B35',      // coral orange (single accent)
          dark: '#E85A24',
          light: '#FF8F5E',
          surface: '#FFF3ED',
          'tint-bg': 'rgba(255, 107, 53, 0.12)',      // D-10
          'tint-border': 'rgba(255, 107, 53, 0.30)',  // D-10
        },
        // Dark-mode surfaces (match web-player :root tokens)
        surface: {
          bg: '#0F1117',
          base: '#1A1D27',
          raised: '#242733',
          border: '#2E3140',
        },
        // Light-mode surfaces (D-08 mirror — defined but not wired up)
        'surface-light': {
          bg: '#FAFAF7',
          base: '#FFFFFF',
          raised: '#F5F5F0',
          border: '#E5E7EB',
        },
        ink: {
          DEFAULT: '#F0F0F5',
          // D-01: secondary resolves to #9CA3AF (was the `muted` role).
          // The old #6B7280 lives on as `dim` for placeholders/helpers.
          muted: '#9CA3AF',
          dim: '#6B7280',
          disabled: '#4B5563',
        },
        // Semantic — D-03 full-word names (ok/warn/err retired).
        success: '#22C55E',
        warning: '#F59E0B',
        error: '#EF4444',
        rest: '#64748B',
      },
      fontFamily: {
        heading: ['Montserrat', 'system-ui', 'sans-serif'],
        sans: ['Inter', 'system-ui', 'sans-serif'],
        mono: ['JetBrains Mono', 'ui-monospace', 'monospace'],
      },
      // D-09: typography scale mirrors tokens.json typography.scale.
      fontSize: {
        'display-lg':  ['57px', { lineHeight: '1.05', letterSpacing: '-1.5px', fontWeight: '800' }],
        'display-md':  ['45px', { lineHeight: '1.1',  letterSpacing: '-0.5px', fontWeight: '700' }],
        'display-sm':  ['36px', { lineHeight: '1.15', letterSpacing: '-0.3px', fontWeight: '700' }],
        'headline-lg': ['32px', { lineHeight: '1.2',  letterSpacing: '-0.5px', fontWeight: '700' }],
        'headline-md': ['28px', { lineHeight: '1.25', letterSpacing: '-0.3px', fontWeight: '700' }],
        'headline-sm': ['24px', { lineHeight: '1.3',  letterSpacing: '-0.2px', fontWeight: '600' }],
        'title-lg':    ['20px', { lineHeight: '1.35', letterSpacing: '-0.3px', fontWeight: '700' }],
        'title-md':    ['16px', { lineHeight: '1.4',  letterSpacing: '0',      fontWeight: '600' }],
        'title-sm':    ['14px', { lineHeight: '1.4',  letterSpacing: '0',      fontWeight: '600' }],
        'body-lg':     ['16px', { lineHeight: '1.5',  letterSpacing: '0',      fontWeight: '400' }],
        'body-md':     ['14px', { lineHeight: '1.5',  letterSpacing: '0',      fontWeight: '400' }],
        'body-sm':     ['12px', { lineHeight: '1.5',  letterSpacing: '0',      fontWeight: '400' }],
        'label-lg':    ['14px', { lineHeight: '1.4',  letterSpacing: '0.1px',  fontWeight: '600' }],
        'label-md':    ['12px', { lineHeight: '1.4',  letterSpacing: '0.5px',  fontWeight: '600' }],
        'label-sm':    ['11px', { lineHeight: '1.4',  letterSpacing: '0.5px',  fontWeight: '600' }],
      },
      // D-04: motion tokens.
      transitionDuration: {
        fast: '150ms',
        normal: '250ms',
        slow: '400ms',
      },
      transitionTimingFunction: {
        standard: 'cubic-bezier(0.2, 0, 0, 1)',
        emphasized: 'cubic-bezier(0.16, 1, 0.3, 1)',
      },
      // D-07: shadow-card retired. Only survivor is the focus ring.
      boxShadow: {
        'focus-ring': '0 0 0 3px rgba(255, 107, 53, 0.30)',
      },
      borderRadius: {
        sm: '8px',
        md: '12px',
        lg: '16px',
        xl: '20px',
      },
    },
  },
  plugins: [],
};

export default config;
