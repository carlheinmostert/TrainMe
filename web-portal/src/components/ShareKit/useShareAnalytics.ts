'use client';

import { useCallback, useMemo } from 'react';

import {
  createPortalShareKitApi,
  type ShareEventChannel,
  type ShareEventKind,
} from '@/lib/supabase/api';
import { getBrowserClient } from '@/lib/supabase-browser';

/**
 * useShareAnalytics — shared hook wiring every share-kit card to the
 * Wave 10 Phase 3 `log_share_event` RPC.
 *
 * Takes the `practiceId` once at the top of the /network page and
 * returns a `log(channel, eventKind, meta?)` thunk each card can wire
 * to its <CopyButton onCopy> / <OpenInAppButton onOpen> callbacks.
 *
 * Every call is fire-and-forget — analytics must never block the user
 * action. The Supabase browser client is memoised once per page render
 * so we don't churn on every call.
 */
export function useShareAnalytics(practiceId: string) {
  const api = useMemo(() => {
    const supabase = getBrowserClient();
    return createPortalShareKitApi(supabase);
  }, []);

  return useCallback(
    (
      channel: ShareEventChannel,
      eventKind: ShareEventKind,
      meta?: Record<string, unknown>,
    ) => {
      // Explicitly `void` the promise so linters don't flag the
      // unhandled rejection — the swallow lives inside logEvent itself.
      void api.logEvent(practiceId, channel, eventKind, meta);
    },
    [api, practiceId],
  );
}

/** Convenience type alias — what each card receives as a prop. */
export type LogShareEvent = ReturnType<typeof useShareAnalytics>;
