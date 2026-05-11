/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Portal is small and static-friendly; default output works for Vercel.
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: '**.supabase.co',
      },
    ],
  },
  // Build-marker plumbing — surface Vercel's git metadata to the client
  // bundle as `NEXT_PUBLIC_*` mirrors so a <BuildInfo /> footer chip can
  // render "<sha> · <branch>" at low opacity in every page. Mirrors the
  // Flutter mobile pattern (build SHA at 35% opacity in the HomefitLogo
  // footer). Falls back to 'dev' / 'local' for local development.
  //
  // Vercel auto-injects VERCEL_GIT_COMMIT_SHA + VERCEL_GIT_COMMIT_REF into
  // every build. The values flow through Next's `env` block at build time
  // and are baked into the static bundle — no runtime fetch needed.
  env: {
    NEXT_PUBLIC_GIT_SHA:
      process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 7) ?? 'dev',
    NEXT_PUBLIC_GIT_BRANCH:
      process.env.VERCEL_GIT_COMMIT_REF ?? 'local',
  },
};

export default nextConfig;
