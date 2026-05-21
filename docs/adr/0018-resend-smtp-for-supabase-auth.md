# Email via Resend SMTP for Supabase auth emails

All Supabase auth emails route through `smtp.resend.com:465` as the SMTP relay. Sender is `noreply@homefit.studio` displaying as "homefit team". Rate limit raised from Supabase's default 4/hour to 30/hour to absorb signup waves. Templates are dark + coral with base64-inlined matrix logo; source of truth lives at `supabase/email-templates/`.
