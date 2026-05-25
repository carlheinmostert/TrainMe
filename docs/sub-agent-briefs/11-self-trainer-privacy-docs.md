# Brief — PR #11: Privacy policy delta + PrivacyInfo.xcprivacy + ASC checklist

**Target branch:** `feat/self-trainer-privacy-docs`
**Target merge:** `staging`
**Depends on:** none (parallel to all other PRs)
**Sensitive zone:** legal — Carl + ZA lawyer red-pen before merge

## Context

`docs/SELF_TRAINER_WAVE.md` § "POPIA compliance". The wave introduces biometric data (face embedding); the privacy policy + Apple privacy manifest + App Store Connect questionnaire all need to reflect this.

## Acceptance criteria

1. **`web-portal/src/app/privacy/page.tsx`** — add a new section under existing "Data we collect" structure:
   > **Biometric data — face recognition**
   > Type: face embedding (numerical vector) derived from the selfie you upload to your Public profile, plus the selfie itself.
   > Purpose: to verify that you are the person in your own captures, so we can offer those captures free of charge. We also use the selfie (separately) for transparency display on premises live pages where you have opted in.
   > Storage: the embedding is stored both on your device (cache, for offline use) and in your homefit.studio account database (Supabase, AWS-hosted, [region TBD lawyer-review]). The selfie image is stored in your account database only.
   > Retention: until you ask us to delete it. You can stop using face verification at any time via Settings → Public profile → Stop using face verification. Account closure also deletes all face data.
   > Sharing: we do not share your face data with third parties. Supabase acts only as our data processor under contract.
   > Your rights under POPIA: access, correct, delete. Contact privacy@homefit.studio.

   **Bracketed wording flagged for lawyer review:** the cross-border transfer clause, the lawful-basis statement, and the data subject rights section. Carl to submit to ZA lawyer with the existing red-pen batch.

2. **`app/ios/Runner/PrivacyInfo.xcprivacy`** — add a new `NSPrivacyCollectedDataType` entry:
   ```xml
   <dict>
     <key>NSPrivacyCollectedDataType</key>
     <string>NSPrivacyCollectedDataTypeSensitiveInfo</string>
     <key>NSPrivacyCollectedDataTypeLinked</key>
     <true/>
     <key>NSPrivacyCollectedDataTypeTracking</key>
     <false/>
     <key>NSPrivacyCollectedDataTypePurposes</key>
     <array>
       <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
     </array>
   </dict>
   ```
   (Confirm exact enum strings against current Apple docs — `NSPrivacyCollectedDataTypeSensitiveInfo` is the closest fit for face embeddings; if Apple has a more specific biometric type, prefer it.)

3. **`docs/app-store-connect-privacy.md`** — mirror the manifest change. Add a line item under "Sensitive Info": "Face recognition data (linked to user; not used for tracking; purpose: App Functionality — self-verification for credit-exempt publishing)".

4. **No code changes** beyond docs + manifest.

5. **Legal review required before merge.** Carl flagged this as ZA lawyer red-pen territory in the wave-level POPIA Q14.4.

## Hard rules

- **Repo-relative paths only**.
- **Legal review required before merge.**
- **No emojis.**
- **Branch**: `feat/self-trainer-privacy-docs`.
