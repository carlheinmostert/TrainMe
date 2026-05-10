# Supabase Auth Email Templates

Branded HTML templates for the 6 Supabase auth emails. Dark theme,
coral CTA, "homefit team" sender, warmer copy than Supabase's
defaults. No hosted images — text-only wordmark to keep the email
tiny and immune to "images blocked" rendering.

## How to apply

Two paths — the API path is faster and reproducible, the dashboard
path is the fallback.

### Path A — Management API (preferred)

The Supabase CLI doesn't expose auth email config, but the
Management API does. The Supabase CLI stores its Personal Access
Token in the macOS Keychain after `supabase login`; we read it
from there and `PATCH /v1/projects/{ref}/config/auth`.

```bash
# From the repo root.
TPL=supabase/email-templates
SUPABASE_PAT=$(security find-generic-password -s "Supabase CLI" -a "supabase" -w \
  | sed 's/^go-keyring-base64://' | base64 -d)
PROJECT_REF=yrwcofhovrcydootivjx

jq -n \
  --rawfile confirm "$TPL/confirm-signup.html" \
  --rawfile magic "$TPL/magic-link.html" \
  --rawfile recovery "$TPL/reset-password.html" \
  --rawfile email_change "$TPL/change-email.html" \
  --rawfile invite "$TPL/invite-user.html" \
  --rawfile reauth "$TPL/reauthentication.html" \
  '{
    smtp_sender_name: "homefit team",
    mailer_subjects_confirmation: "Welcome to homefit.studio — confirm your email",
    mailer_subjects_magic_link: "Your homefit.studio sign-in link",
    mailer_subjects_recovery: "Reset your homefit.studio password",
    mailer_subjects_email_change: "Confirm your new homefit.studio email",
    mailer_subjects_invite: "You'"'"'re invited to homefit.studio",
    mailer_subjects_reauthentication: "Confirm it'"'"'s you",
    mailer_templates_confirmation_content: $confirm,
    mailer_templates_magic_link_content: $magic,
    mailer_templates_recovery_content: $recovery,
    mailer_templates_email_change_content: $email_change,
    mailer_templates_invite_content: $invite,
    mailer_templates_reauthentication_content: $reauth
  }' \
| curl -sS -X PATCH \
    -H "Authorization: Bearer $SUPABASE_PAT" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth"
```

`200 OK` with no body means success. Verify by fetching the same
endpoint with `GET` and reading back the fields.

### Path B — Dashboard (fallback)

If the Keychain token isn't available (e.g. fresh machine, no
`supabase login` run yet), paste manually:

For each row in the table below:

1. Supabase dashboard → **Authentication** → **Email Templates**
2. Pick the template type from the dropdown
3. Paste the matching file's contents into **Message body**
4. Set **Subject** to the value below
5. Click **Save**

Then in the same Authentication area:

- **SMTP Settings** → change **Sender name** from `homefit.studio` to
  `homefit team` (warmer inbox display name; the email address
  stays `noreply@homefit.studio`)

## Templates and subjects

| File | Supabase template | Subject |
|------|-------------------|---------|
| `confirm-signup.html` | Confirm signup | Welcome to homefit.studio — confirm your email |
| `magic-link.html` | Magic Link | Your homefit.studio sign-in link |
| `reset-password.html` | Reset Password | Reset your homefit.studio password |
| `change-email.html` | Change Email Address | Confirm your new homefit.studio email |
| `invite-user.html` | Invite User | You're invited to homefit.studio |
| `reauthentication.html` | Reauthentication | Confirm it's you |

## Variables in use

Supabase substitutes these at send time:

- `{{ .ConfirmationURL }}` — full URL with token, used as the CTA
  button target on five of the six templates
- `{{ .Token }}` — 6-digit OTP code, used in reauthentication only
- `{{ .NewEmail }}` — used only in change-email.html

`{{ .Email }}` and `{{ .SiteURL }}` are also available but the current
templates don't reference them.

## Design notes

- **Dark theme** (`#0F1117` bg, `#FFFFFF` headings, `#9CA3AF` body)
  matches the mobile app and the web player
- **Coral CTA** (`#FF6B35`) — single brand accent, no exceptions
- **System font stack** — email clients strip web fonts. Falls
  through SF Pro / Segoe UI / Roboto / Helvetica
- **Table-based layout** for Outlook compatibility
- **Inline styles only** — Gmail strips `<style>` blocks

## Testing each template

Send one of each to your own inbox:

| Template | Trigger |
|----------|---------|
| Confirm signup | Sign up a fresh test email at manage.homefit.studio |
| Magic Link | Sign in with email at manage.homefit.studio |
| Reset Password | Click "forgot password" on portal sign-in |
| Change Email | Change email in account settings |
| Invite User | Invite a practitioner from a practice you own |
| Reauthentication | Triggered by sensitive Supabase dashboard actions |

Inbox to test in: iOS Mail (most practitioners), Gmail web, Gmail iOS,
Outlook web. Look for: dark background renders, coral button readable,
layout doesn't break on narrow screens, `homefit team` shows as the
sender name.

## Logo

The matrix logo at the top of every template is a 768×152px PNG
inlined as a base64 data URI in the `<img src>`. Source-of-truth
geometry lives in `web-portal/src/components/HomefitLogo.tsx`; the
PNG is rendered by `tools/email-logo-render/render.py`, which also
substitutes the inlined block across all 6 template files in one go.

**Re-render after any geometry change:**

```bash
python3 tools/email-logo-render/render.py
```

This rewrites `web-portal/public/email/logo.png` and re-inlines into
all 6 `supabase/email-templates/*.html` files. Then re-apply via the
Path A one-liner above.

**Why inlined base64 rather than a hosted URL?** The hosted approach
needs `https://manage.homefit.studio/email/logo.png` to be live before
the email can render the logo, which means waiting for Vercel deploy
on every change. Inlined base64 works the moment Supabase accepts the
PATCH. ~2.5KB of overhead per email is negligible. Trade-off: Outlook
desktop (rare among practitioners) doesn't render data-URI images and
shows the alt text instead — the text wordmark below the logo still
reads brand-correct, so the email isn't broken, just slightly less
polished there.
