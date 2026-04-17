type Props = {
  balance: number;
};

export function CreditBalance({ balance }: Props) {
  const isLow = balance < 5;
  return (
    <div
      className="rounded-lg border border-surface-border bg-surface-base p-5 shadow-card"
      role="status"
      aria-live="polite"
    >
      <p className="text-xs font-medium uppercase tracking-wider text-ink-muted">
        Credit balance
      </p>
      <p className="mt-2 font-heading text-4xl font-bold text-ink">
        <span className={isLow ? 'text-warn' : 'text-brand'}>{balance}</span>
        <span className="ml-2 text-base font-normal text-ink-muted">
          {balance === 1 ? 'credit' : 'credits'}
        </span>
      </p>
      {isLow && (
        <p className="mt-2 text-xs text-warn">
          Running low — top up before your next publish.
        </p>
      )}
    </div>
  );
}
