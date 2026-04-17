import type { Config } from 'tailwindcss';

// Brand tokens mirror app/lib/theme.dart and web-player/styles.css :root.
// Keep these in sync when the brand system evolves.
const config: Config = {
  content: ['./src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          DEFAULT: '#FF6B35',      // coral orange (primary accent)
          dark: '#E85A24',
          light: '#FF8F5E',
          surface: '#FFF3ED',
        },
        // Dark-mode surfaces (match web-player :root tokens)
        surface: {
          bg: '#0F1117',
          base: '#1A1D27',
          raised: '#242733',
          border: '#2E3140',
        },
        ink: {
          DEFAULT: '#F0F0F5',
          muted: '#9CA3AF',
          dim: '#6B7280',
        },
        // Semantic
        ok: '#22C55E',
        warn: '#F59E0B',
        err: '#EF4444',
        rest: '#64748B',
      },
      fontFamily: {
        heading: ['Montserrat', 'system-ui', 'sans-serif'],
        sans: ['Inter', 'system-ui', 'sans-serif'],
      },
      boxShadow: {
        card: '0 1px 3px rgba(0,0,0,0.35), 0 4px 12px rgba(0,0,0,0.25)',
        'brand-glow': '0 4px 16px rgba(255, 107, 53, 0.35)',
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
