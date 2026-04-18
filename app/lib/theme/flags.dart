// ---------------------------------------------------------------------------
// HomeFit Studio — Theme feature flags (D-08)
// ---------------------------------------------------------------------------
//
// Light-theme tokens exist as a mirror of the dark system so we can flip a
// single switch when the second-bio onboarding polish lands. Until then the
// MaterialApp stays locked to AppTheme.dark.
//
// Flip this to true to serve AppTheme.light for users with
// MediaQuery.platformBrightnessOf(context) == Brightness.light.

const bool kEnableLightTheme = false;
