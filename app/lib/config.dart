/// Raidme app configuration
///
/// These values are safe for client-side use.
/// The publishable key is designed to be public — Row Level Security
/// controls what it can access.
class AppConfig {
  static const String supabaseUrl = 'https://yrwcofhovrcydootivjx.supabase.co';
  static const String supabaseAnonKey = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

  /// Base URL for shared plan links (web player)
  /// TODO: Update when domain is registered
  static const String webPlayerBaseUrl = 'https://raidme.vercel.app';

  /// Video recording constraints
  static const int maxVideoSeconds = 30;
  static const int videoWarningSeconds = 15;

  /// Line drawing conversion defaults
  static const int blurKernel = 31;
  static const int thresholdBlock = 9;
  static const int contrastLow = 80;
}
