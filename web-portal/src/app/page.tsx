import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { BrandHeader } from '@/components/BrandHeader';
import { SignInGate } from '@/components/SignInGate';

// Home — authenticated users jump to /dashboard, everyone else sees sign-in.
export default async function HomePage() {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (user) {
    redirect('/dashboard');
  }

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader />
      <div className="flex flex-1 items-center justify-center px-6 py-12">
        <SignInGate />
      </div>
    </main>
  );
}
