'use client';

// Shared Google OAuth button — used by both the sign-in and sign-up gates.
// Extracted 2026-04-19 (chore/web-simplify) to eliminate the 30-line SVG path
// and identical button classes that were duplicated verbatim across
// SignInGate.tsx and SignUpGate.tsx.
//
// The dark text colour (#1f1f1f) is deliberate — Google's sign-in brand
// guidelines require the specific dark-on-white treatment, so we intentionally
// do NOT swap it for a `text-ink` token.

type Props = {
  onClick: () => void;
  loading: boolean;
  /** "Signing in…" vs "Signing in…" is the same today; kept as a prop so the
   * sign-up gate can pick its own copy without reworking the button. */
  loadingLabel?: string;
  /** Default "Continue with Google" — callers rarely need to override. */
  label?: string;
};

export function GoogleSignInButton({
  onClick,
  loading,
  loadingLabel = 'Signing in\u2026',
  label = 'Continue with Google',
}: Props) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={loading}
      className="flex w-full items-center justify-center gap-3 rounded-md bg-white px-4 py-3 text-sm font-medium text-[#1f1f1f] transition hover:bg-ink disabled:cursor-not-allowed disabled:opacity-60"
    >
      <GoogleIcon />
      {loading ? loadingLabel : label}
    </button>
  );
}

function GoogleIcon() {
  return (
    <svg
      className="h-5 w-5"
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 48 48"
      aria-hidden="true"
    >
      <path
        fill="#FFC107"
        d="M43.6 20.5H42V20H24v8h11.3c-1.6 4.6-6 8-11.3 8-6.6 0-12-5.4-12-12s5.4-12 12-12c3 0 5.8 1.1 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"
      />
      <path
        fill="#FF3D00"
        d="M6.3 14.7l6.6 4.8C14.7 15.9 19 13 24 13c3 0 5.8 1.1 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"
      />
      <path
        fill="#4CAF50"
        d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.8 36 24 36c-5.3 0-9.7-3.4-11.3-8l-6.5 5C9.6 39.6 16.2 44 24 44z"
      />
      <path
        fill="#1976D2"
        d="M43.6 20.5H42V20H24v8h11.3c-.8 2.3-2.3 4.3-4.1 5.6l6.2 5.2C41.1 36.1 44 30.6 44 24c0-1.3-.1-2.4-.4-3.5z"
      />
    </svg>
  );
}
