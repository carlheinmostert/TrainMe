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
};

export default nextConfig;
