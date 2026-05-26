// Regression tests for the persistent Safe Mode banner.
//
// Tracks: stack round 4 (2026-05-26) — items M24 / M26 / M27.
//
// The banner sits ABOVE the Navigator (mounted via `MaterialApp.builder`)
// and any in-app sheet path silently failed because `Navigator.of(context)`
// could not walk up to find one. Item M27's fix routes the tap straight
// out via `launchUrl` to the env-aware portal subscribe URL.
//
// Item M26 added an `AppLifecycleState.resumed` hook + a banner-mount
// `refreshThrottled()` call so the subscribed-state cache cannot sit
// stale for up to an hour when the practitioner subscribes from the
// portal while the app is backgrounded. These tests assert the wiring
// is structurally correct — the file references the canonical
// `SafeModeSubscriptionService` singleton (no forked state path) and
// uses the throttled-refresh entry point that the spec mandates.
//
// We deliberately keep these tests file-content-shaped rather than
// pumping a full widget tree: `SafeModeService` + `SafeModeSubscriptionService`
// are app-level singletons with `initialize()` plumbing that is hard
// to spin up cleanly inside a unit-test isolate. The regression we
// care about is "does the banner still wire to the canonical SoT?" —
// that's a code-shape property and a content scan catches drift.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PersistentSafeModeBanner — M26 regression guard', () {
    late String source;

    setUpAll(() {
      // Test runs from app/ so the path is repo-relative to that root.
      source = File('lib/widgets/persistent_safe_mode_banner.dart')
          .readAsStringSync();
    });

    test(
      'reads subscription state from the canonical SafeModeSubscriptionService '
      '(no forked state path)',
      () {
        // Banner must import the singleton.
        expect(
          source,
          contains("import '../services/safe_mode_subscription_service.dart'"),
          reason: 'banner must wire to the canonical subscription service',
        );

        // Must access `hasAccess` on the singleton — not a private
        // state path or a parallel cache.
        expect(
          source.contains('SafeModeSubscriptionService.instance.hasAccess'),
          isTrue,
          reason:
              'banner must source the subscribed/not-subscribed render path '
              'from SafeModeSubscriptionService.instance.hasAccess (the same '
              'value the capture-gate reads — no parallel cache).',
        );
      },
    );

    test(
      'refreshes subscription cache on mount AND on AppLifecycleState.resumed',
      () {
        // `WidgetsBindingObserver` must be mixed in so the state can
        // hook `didChangeAppLifecycleState`.
        expect(
          source.contains('WidgetsBindingObserver'),
          isTrue,
          reason:
              'banner state must mix in WidgetsBindingObserver to refresh '
              'the subscription cache on app resume.',
        );

        expect(
          source.contains('didChangeAppLifecycleState'),
          isTrue,
          reason: 'banner must override didChangeAppLifecycleState',
        );

        // Lifecycle hook + mount call both go through refreshThrottled —
        // the throttle keeps rapid foreground/background switches from
        // hammering the RPC. `refreshIfStale` would leave a fresh-but-
        // wrong cache untouched for up to an hour after a portal-side
        // subscribe; that's exactly the M26 bug.
        expect(
          source.contains('refreshThrottled()'),
          isTrue,
          reason:
              'banner must call refreshThrottled (NOT refreshIfStale) so a '
              'portal-side subscribe is picked up within the throttle window.',
        );

        // Lifecycle observer must be registered + removed.
        expect(
          source.contains('addObserver(this)'),
          isTrue,
          reason: 'lifecycle observer must be registered in initState',
        );
        expect(
          source.contains('removeObserver(this)'),
          isTrue,
          reason: 'lifecycle observer must be removed in dispose',
        );
      },
    );
  });

  group('PersistentSafeModeBanner — M27 regression guard', () {
    late String source;

    setUpAll(() {
      source = File('lib/widgets/persistent_safe_mode_banner.dart')
          .readAsStringSync();
    });

    test(
      'tap path routes to the portal subscribe URL via launchUrl '
      '(not an in-app modal sheet)',
      () {
        // launchUrl is the only valid path because the banner sits
        // above the Navigator — showModalBottomSheet silently fails.
        expect(
          source.contains('launchUrl(uri,'),
          isTrue,
          reason:
              'banner tap must hand off to launchUrl with the portal URI; '
              'in-app showModalBottomSheet would silently fail because the '
              'banner is mounted above the Navigator (M27).',
        );

        // Must use the env-aware portalLink helper so staging builds
        // land on staging.manage.homefit.studio.
        expect(
          source.contains("portalLink('/safe-mode/subscribe')"),
          isTrue,
          reason:
              'not-subscribed tap must build the URL via portalLink so the '
              'ENV dart-define resolves to staging vs prod correctly.',
        );

        // Must NOT call showSafeModePaywallSheet from the banner —
        // the regression that broke tap was routing through that
        // sheet, which failed to find a Navigator ancestor.
        expect(
          source.contains('showSafeModePaywallSheet'),
          isFalse,
          reason:
              'banner must NOT invoke showSafeModePaywallSheet (it requires '
              'a Navigator ancestor which the banner does not have — that is '
              'the M27 bug).',
        );
      },
    );

    test(
      'subscribed-state tap path opens the portal manage page',
      () {
        expect(
          source.contains("portalLink('/safe-mode')"),
          isTrue,
          reason:
              'subscribed tap must open the portal /safe-mode manage page '
              '(Reader-App compliant — cancel/change-plan happens out of app).',
        );
      },
    );
  });

  group('SafeModeToggleButton — M24 regression guard', () {
    late String source;

    setUpAll(() {
      source = File('lib/widgets/safe_mode_toggle_button.dart')
          .readAsStringSync();
    });

    test(
      'icon renders the green badge in every state — no coral, no white '
      'shield outline',
      () {
        // M24: the icon must always render with the sage tokens.
        // The legacy off-state used `AppColors.textOnDark` for the
        // shield fill + `AppColors.surfaceBg` for the knockout; the
        // legacy manual state used `AppColors.primary` for the pill
        // background + border. Both are gone in M24 — colour ONLY
        // comes from the sage tokens.
        expect(
          source.contains('_kSageFill'),
          isTrue,
          reason: 'green badge must reference the sage fill token',
        );
        expect(
          source.contains('_kSageBorder'),
          isTrue,
          reason: 'green badge must reference the sage border token',
        );

        // The old off-state used `AppColors.textOnDark` as the shield
        // fill — that branch must be gone. The grep is allowed to
        // match unrelated uses; the regression check is that the
        // off-shield's `fillColor: AppColors.textOnDark` line is
        // absent.
        expect(
          source.contains('fillColor: AppColors.textOnDark'),
          isFalse,
          reason:
              'off-state shield must not fall back to textOnDark fill (M24 '
              'requires the icon to stay green in every state).',
        );

        // The old manual-state used a coral pill (`AppColors.primary`)
        // as the container background — that branch must be gone.
        expect(
          source.contains('AppColors.primary.withValues(alpha: 0.10)'),
          isFalse,
          reason:
              'manual-state coral pill background must be gone — M24 keeps '
              'the icon green in manual mode too.',
        );
      },
    );
  });
}
