import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Single enumerated Supabase surface for the Flutter app.
///
/// Per `docs/DATA_ACCESS_LAYER.md` the app's interaction with Supabase is
/// confined to typed methods on this class — no ad-hoc `Supabase.instance
/// .client.rpc(...)` calls from screens or other services. The goal is one
/// list of "what the mobile app can ask the backend to do" in one file.
///
/// Incremental migration: legacy call sites (auth bootstrap, publish flow)
/// still reach straight into `Supabase.instance.client`. New features are
/// being routed through [ApiClient] first and older surfaces will follow.
/// Today's initial scope is the referral RPCs; adding a method here is the
/// only correct place to introduce new backend calls from the mobile app.
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  SupabaseClient get _supabase => Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Referral
  // ---------------------------------------------------------------------------

  /// Fetch (or create) the referral code for [practiceId].
  ///
  /// Wraps the `generate_referral_code` RPC. The backend implementation is
  /// idempotent — calling it repeatedly for the same practice returns the
  /// same code, so the client can call this on every Settings → Network
  /// render without worrying about collisions.
  ///
  /// Throws if the RPC fails or returns a non-string payload; callers are
  /// expected to handle errors and retry (e.g. the "Couldn't load — tap to
  /// retry" row in Settings).
  Future<String> ensureReferralCode(String practiceId) async {
    final result = await _supabase.rpc(
      'generate_referral_code',
      params: {'p_practice_id': practiceId},
    );
    if (result is String && result.isNotEmpty) return result;
    // Some PostgREST responses wrap scalars — defensive unwrap.
    if (result is List && result.isNotEmpty) {
      final first = result.first;
      if (first is String && first.isNotEmpty) return first;
      if (first is Map && first['generate_referral_code'] is String) {
        return first['generate_referral_code'] as String;
      }
    }
    throw StateError(
      'generate_referral_code returned unexpected payload: $result',
    );
  }

  /// Fetch aggregate referral stats for [practiceId].
  ///
  /// Wraps the `referral_dashboard_stats` RPC which returns a single row
  /// with four numeric columns. The PostgREST flavour returns this either
  /// as a bare Map or a List-of-one-Map depending on RPC return semantics;
  /// we tolerate both shapes.
  Future<ReferralStats> getReferralStats(String practiceId) async {
    final result = await _supabase.rpc(
      'referral_dashboard_stats',
      params: {'p_practice_id': practiceId},
    );
    Map<String, dynamic>? row;
    if (result is Map<String, dynamic>) {
      row = result;
    } else if (result is List && result.isNotEmpty) {
      final first = result.first;
      if (first is Map<String, dynamic>) row = first;
    }
    if (row == null) {
      debugPrint('referral_dashboard_stats unexpected payload: $result');
      throw StateError('referral_dashboard_stats returned no row');
    }
    return ReferralStats.fromJson(row);
  }
}

/// Aggregate stats for a practice's referral network.
///
/// Mirrors the four columns returned by the `referral_dashboard_stats`
/// RPC. Lives alongside [ApiClient] rather than in a generic models
/// folder because it's API-surface-specific — the RPC is the schema.
@immutable
class ReferralStats {
  final num rebateBalanceCredits;
  final num lifetimeRebateCredits;
  final int refereeCount;
  final num qualifyingSpendTotalZar;

  const ReferralStats({
    required this.rebateBalanceCredits,
    required this.lifetimeRebateCredits,
    required this.refereeCount,
    required this.qualifyingSpendTotalZar,
  });

  /// Safe constructor for "no data yet" states so callers can render the
  /// shell without a null-check everywhere. Not used for error states —
  /// error states surface as a thrown exception from [ApiClient].
  static const empty = ReferralStats(
    rebateBalanceCredits: 0,
    lifetimeRebateCredits: 0,
    refereeCount: 0,
    qualifyingSpendTotalZar: 0,
  );

  factory ReferralStats.fromJson(Map<String, dynamic> json) {
    num asNum(dynamic v) {
      if (v is num) return v;
      if (v is String) return num.tryParse(v) ?? 0;
      return 0;
    }

    int asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    return ReferralStats(
      rebateBalanceCredits: asNum(json['rebate_balance_credits']),
      lifetimeRebateCredits: asNum(json['lifetime_rebate_credits']),
      refereeCount: asInt(json['referee_count']),
      qualifyingSpendTotalZar: asNum(json['qualifying_spend_total_zar']),
    );
  }
}
