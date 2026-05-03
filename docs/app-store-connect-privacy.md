# App Store Connect — App Privacy form click-through

This guide pairs the in-binary privacy manifest at `app/ios/Runner/PrivacyInfo.xcprivacy` with the manual "App Privacy" form in App Store Connect. **Apple validates the two against each other and rejects mismatches** — fill the form using the answers below verbatim.

References:
- Apple — Privacy manifest files: https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
- App Store Review Guidelines §5.1 (Privacy): https://developer.apple.com/app-store/review/guidelines/#privacy
- Apple — Describing data use in privacy manifests: https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_data_use_in_privacy_manifests
- App Store Connect — App Privacy details (Apple Help): https://developer.apple.com/help/app-store-connect/manage-app-privacy/manage-app-privacy

Companion artefact: `app/ios/Runner/PrivacyInfo.xcprivacy` — must agree with this form.
Companion task (separate): the public privacy policy hosted at `homefit.studio/privacy` (research agent in flight).

---

## Step 1 — Top-level questions

App Store Connect → My Apps → homefit.studio → **App Privacy** → Get Started.

| Question | Answer | Notes |
|---|---|---|
| Do you or your third-party partners collect data from this app? | **Yes** | The app collects practitioner email, client names, captured media, audit events. |
| Do you or your third-party partners use data for tracking? | **No** | No third-party analytics, no IDFA access, no advertising SDKs, no cross-app/website linking. `NSPrivacyTracking = false` in the manifest. |

---

## Step 2 — Data Types collected

For each of the 9 rows below: tick the Apple category, mark **Collected = Yes**, **Linked to user = Yes**, **Used for tracking = No**, then tick the listed Purposes.

| # | Apple category (form path) | Manifest constant | Linked? | Tracking? | Purposes | Rationale (one-liner Carl can paste) |
|---|---|---|---|---|---|---|
| 1 | Contact Info → Email Address | `NSPrivacyCollectedDataTypeEmailAddress` | Yes | No | App Functionality | Practitioner sign-in via Supabase magic link / password. |
| 2 | Contact Info → Name | `NSPrivacyCollectedDataTypeName` | Yes | No | App Functionality | The practitioner enters client names so plans can be addressed and recalled. Names may be anonymised (e.g. "Practice 1"). |
| 3 | User Content → Photos or Videos | `NSPrivacyCollectedDataTypePhotosOrVideos` | Yes | No | App Functionality | Practitioner captures or imports videos and photos of exercise demonstrations during a session. |
| 4 | User Content → Audio Data | `NSPrivacyCollectedDataTypeAudioData` | Yes | No | App Functionality | Audio is recorded with the exercise video so the practitioner can include verbal cues for the client. |
| 5 | User Content → Other User Content | `NSPrivacyCollectedDataTypeOtherUserContent` | Yes | No | App Functionality | Plan title, exercise notes, reps / sets / hold seconds, custom durations, per-treatment client video consent flags. |
| 6 | Identifiers → User ID | `NSPrivacyCollectedDataTypeUserID` | Yes | No | App Functionality | Supabase user UUID — server-side identifier scoped to the homefit.studio backend (multi-tenant practice membership). Not an advertising ID. |
| 7 | Purchases → Purchase History | `NSPrivacyCollectedDataTypePurchaseHistory` | Yes | No | App Functionality | Credit-bundle purchases via PayFast. The app stores ledger rows (`credit_ledger`, `plan_issuances`); card data is handled by PayFast and never reaches the app. |
| 8 | Usage Data → Product Interaction | `NSPrivacyCollectedDataTypeProductInteraction` | Yes | No | Analytics, App Functionality | Plan publish events and credit consumption events recorded server-side as a billing audit trail. Used for invoicing and credit accounting, not behavioural analytics. |

> Note: Apple's taxonomy combines photos and videos into a single category, **"Photos or Videos"** — one tickbox covers both video capture and photo capture. The manifest constant is `NSPrivacyCollectedDataTypePhotosOrVideos`.

### What "Linked to user" means here

Every collected data type is tied to the practitioner's Supabase account (email + UUID), so all 8 rows are Linked = Yes. Even client names are linked, because they're stored under the practitioner's practice. Choose **Linked to user** for each.

### What "Tracking" would have meant (and why we say No)

Apple defines tracking as linking data with third-party data for advertising, or sharing it with a data broker. None of that happens. The app has no Firebase, no Sentry, no Mixpanel, no GA, no Amplitude, no IDFA access, and no advertising SDKs. **All 8 rows: Used for tracking = No.**

---

## Step 3 — Per-data-type detail prompts

App Store Connect asks 2-3 follow-up questions per data type. The answers are uniform:

| Follow-up | Answer for all 8 rows |
|---|---|
| Is this data collected from this app linked to the user's identity? | **Yes** |
| Do you or your third-party partners use this data to track users? | **No** |
| What are all of the purposes for which this data is collected and/or used? | See "Purposes" column above. |

For row #8 (Product Interaction) tick **both** Analytics and App Functionality. For all other rows tick **only App Functionality**.

The form may also offer "Optional" purposes such as Third-Party Advertising, Developer's Advertising or Marketing, Product Personalization. **Leave all of those unticked** — they don't apply.

---

## Step 4 — Third-party SDKs note

App Store Connect asks whether any third-party SDKs in the app collect data. The honest answer is:

- **Supabase** — server backend (auth, Postgres, storage, edge functions). It is not a tracking SDK; it stores the practitioner's data on our behalf for App Functionality. Disclosed via the data types above.
- **PayFast** — payment processor. Card data is entered on PayFast's hosted checkout (web view / browser handover); the app never sees PAN / CVV. PayFast operates under its own privacy disclosures. Practitioner email and a transaction reference are passed to PayFast as part of checkout — already covered by the Email Address + Purchase History rows.

No analytics SDKs, no crash reporters, no advertising SDKs are linked into the iOS binary. Tick **No** on any prompt that asks whether third-party partners collect data, except where the form explicitly distinguishes payment processors — in which case disclose PayFast as a payment processor only.

---

## Step 5 — Data Retention and Deletion (if prompted)

App Store Connect may ask about retention. Brief answers Carl can adapt:

| Prompt | Answer |
|---|---|
| Do you provide a way to delete account data? | Yes — practitioner can delete their account by emailing support; client records soft-delete with a 7-day recycle bin. |
| Where is data stored? | Supabase (EU region). |
| Do you encrypt data in transit? | Yes — TLS for all network traffic; signed URLs for media playback. |

---

## Step 5b — Info.plist purpose strings (cross-check)

These are not part of the App Privacy form, but Apple Review cross-checks them against actual app behaviour. If wording drifts from when/why the prompt fires, expect a rejection.

| Key | Current copy |
|---|---|
| `NSCameraUsageDescription` | homefit.studio uses your camera to capture exercise demonstrations during client sessions. |
| `NSMicrophoneUsageDescription` | homefit.studio records audio when you capture video demonstrations so you can include verbal cues. |
| `NSPhotoLibraryUsageDescription` | homefit.studio needs access to your photo library to import existing videos or photos of exercises into client plans. |
| `NSPhotoLibraryAddUsageDescription` | homefit.studio saves the original photo or video of every exercise you capture into your Photos library so you keep a personal copy. You can turn this off in Settings → Session capture. |

The `Add` purpose string was updated 2026-05-03 (post-PR #197) to reflect the default-ON auto-save behaviour — the prompt now fires on first capture, not on a manual Download tap. Practitioners can opt out via Settings → Session capture.

---

## Step 6 — Required-Reason API declarations (already in the manifest)

These are **not** part of the App Privacy form, but Apple cross-checks them at upload. The manifest declares:

| API category | Reason code | What we use it for |
|---|---|---|
| `NSPrivacyAccessedAPICategoryUserDefaults` | CA92.1 | Own-app `UserDefaults` via `SharedPreferences` (practice picker, body-focus toggle). |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | C617.1 | Display capture timestamps on thumbnails / session cards. |
| `NSPrivacyAccessedAPICategorySystemBootTime` | 35F9.1 | Measure elapsed time (Flutter / video pipeline timers). |
| `NSPrivacyAccessedAPICategoryDiskSpace` | E174.1 | Write user-generated media to disk (raw archive + line-drawing converted output). |

If you add a new SDK or a new system API call, audit `NSPrivacyAccessedAPITypes` again before the next TestFlight upload.

---

## Step 7 — Submission checklist

Before tapping **Publish** on the App Privacy form:

- [ ] All 8 data types ticked with the table values above.
- [ ] Tracking question: No.
- [ ] No advertising/tracking SDK rows accidentally enabled.
- [ ] Privacy Policy URL field set to `https://homefit.studio/privacy` (gap analysis is a separate task — make sure the page is live before submission).
- [ ] `app/ios/Runner/PrivacyInfo.xcprivacy` matches this form (re-read the file if anything was edited mid-review).
- [ ] `plutil -lint app/ios/Runner/PrivacyInfo.xcprivacy` returns OK.

After publish, run a fresh archive + TestFlight upload. Apple's validator surfaces a privacy-mismatch warning at upload time if anything drifts.
