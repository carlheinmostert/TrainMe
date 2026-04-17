// Credit bundle catalog — shared between server (purchase route, ITN webhook
// expected-amount check) and client (/credits page UI). Keeping this as a
// plain TS constant (not a DB table) for the POV is intentional: prices are
// rare-changing and shipping a new deploy is cheaper than building a pricing
// admin surface. If we ever need versioned pricing, lift this to a Supabase
// table and add a `priced_at` snapshot to `pending_payments`.

export type BundleKey = 'starter' | 'practice' | 'clinic';

export type Bundle = {
  key: BundleKey;
  name: string;
  credits: number;
  priceZar: number; // whole rand; we render and transmit with 2 decimals.
  description: string;
};

export const BUNDLES: readonly Bundle[] = [
  {
    key: 'starter',
    name: 'Starter',
    credits: 10,
    priceZar: 250,
    description: '10 credits for homefit.studio',
  },
  {
    key: 'practice',
    name: 'Practice',
    credits: 50,
    priceZar: 1125,
    description: '50 credits for homefit.studio',
  },
  {
    key: 'clinic',
    name: 'Clinic',
    credits: 200,
    priceZar: 4000,
    description: '200 credits for homefit.studio',
  },
] as const;

export function getBundle(key: string): Bundle | undefined {
  return BUNDLES.find((b) => b.key === key);
}

export function zar(amount: number): string {
  return new Intl.NumberFormat('en-ZA', {
    style: 'currency',
    currency: 'ZAR',
    maximumFractionDigits: 0,
  }).format(amount);
}

/** Format as PayFast's `amount` field expects: two decimals, no thousands sep. */
export function formatAmountZar(priceZar: number): string {
  return priceZar.toFixed(2);
}
