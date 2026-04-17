'use client';

import { useRouter, useSearchParams, usePathname } from 'next/navigation';

export type PracticeSummary = {
  id: string;
  name: string;
  role: 'owner' | 'practitioner';
};

type Props = {
  practices: PracticeSummary[];
  selectedId: string;
};

// URL-param driven switcher. No global state — each navigation carries the
// ?practice=<id> query through. Server components read it via searchParams.
export function PracticeSwitcher({ practices, selectedId }: Props) {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();

  if (practices.length <= 1) {
    return (
      <p className="text-sm text-ink-muted">
        <span className="text-ink">{practices[0]?.name ?? 'No practice'}</span>
      </p>
    );
  }

  function handleChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const params = new URLSearchParams(search?.toString() ?? '');
    params.set('practice', e.target.value);
    router.push(`${pathname}?${params.toString()}`);
  }

  return (
    <label className="flex items-center gap-2 text-sm">
      <span className="text-ink-muted">Practice:</span>
      <select
        value={selectedId}
        onChange={handleChange}
        className="rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-ink focus:border-brand"
      >
        {practices.map((p) => (
          <option key={p.id} value={p.id}>
            {p.name}
            {p.role === 'owner' ? ' (owner)' : ''}
          </option>
        ))}
      </select>
    </label>
  );
}
