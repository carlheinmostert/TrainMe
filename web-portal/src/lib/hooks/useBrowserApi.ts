'use client';

import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  createPortalAuditApi,
  createPortalMembersApi,
  createPortalReferralApi,
  createPortalShareKitApi,
} from '@/lib/supabase/api';

/**
 * Returns a PortalApi instance backed by the browser Supabase client.
 *
 * Replaces the repeated two-liner:
 *   const supabase = getBrowserClient();
 *   const api = createPortalApi(supabase);
 *
 * Call inside event handlers or effects — NOT at module level — since
 * getBrowserClient() reads env vars that aren't available until runtime.
 */
export function useBrowserApi() {
  const supabase = getBrowserClient();
  return createPortalApi(supabase);
}

export function useBrowserMembersApi() {
  return createPortalMembersApi(getBrowserClient());
}

export function useBrowserAuditApi() {
  return createPortalAuditApi(getBrowserClient());
}

export function useBrowserReferralApi() {
  return createPortalReferralApi(getBrowserClient());
}

export function useBrowserShareKitApi() {
  return createPortalShareKitApi(getBrowserClient());
}
