// Safe Mode Transparency — Phase D (2026-05-22)
//
// Edge function invoked by the `report_session` RPC (via pg_net) when a
// bystander reports a practitioner on the live transparency page.
//
// Responsibilities:
//   1. Fetch the report + practice contact details.
//   2. Send an email to the practice's listed `contact_email` via Resend.
//   3. Stamp `practice_notified_at = now()` on success.
//
// WhatsApp routing is deferred: the `practice_whatsapp_notified_at`
// column exists on the table; this function leaves it NULL for now.
// TODO(phase-d-followup): wire up a WhatsApp provider (Twilio / Meta) and
// stamp that column when the message lands.
//
// Daily digest of unanswered (escalated_at IS NULL after 48h) reports
// is out of scope for this build. See docs/BACKLOG.md.
//
// Spec: docs/specs/2026-05-22-safe-mode-transparency.md

// deno-lint-ignore-file no-explicit-any
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.46.1';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY') ?? '';
const FROM_ADDRESS =
  Deno.env.get('SAFE_MODE_REPORT_FROM') ?? 'noreply@homefit.studio';
const FROM_NAME =
  Deno.env.get('SAFE_MODE_REPORT_FROM_NAME') ?? 'homefit Safe Mode';
const ESCALATION_BCC = Deno.env.get('SAFE_MODE_REPORT_BCC') ?? '';

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// ---------------------------------------------------------------------------
// HTTP entry
// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  // pg_net invokes with POST + JSON body. Anything else is a healthcheck.
  if (req.method !== 'POST') {
    return new Response('OK', { status: 200 });
  }

  let payload: { report_id?: string; session_id?: string; practice_id?: string };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ ok: false, error: 'bad-json' }, 400);
  }

  const reportId = String(payload.report_id ?? '');
  if (!reportId) {
    return jsonResponse({ ok: false, error: 'missing-report-id' }, 400);
  }

  try {
    const report = await loadReport(reportId);
    if (!report) {
      return jsonResponse({ ok: false, error: 'report-not-found' }, 404);
    }

    const contact = await loadPracticeContact(report.practice_id);
    const practitioner = await loadPractitioner(report.trainer_id);

    if (!contact?.email) {
      // Nowhere to send. Stamp escalated_at so the future digest cron
      // surfaces this for the homefit team.
      await admin
        .from('safe_mode_session_reports')
        .update({ escalated_at: new Date().toISOString() })
        .eq('id', reportId);
      return jsonResponse({ ok: false, error: 'no-contact-email' }, 200);
    }

    const sent = await sendEmail({
      to: contact.email,
      practiceName: contact.practiceName,
      practitionerName: practitioner
        ? `${practitioner.first_name ?? ''} ${practitioner.last_name ?? ''}`.trim()
        : 'a practitioner',
      reason: report.reason,
      reportedAt: report.reported_at,
      premisesName: report.premises_name ?? '',
    });

    if (sent) {
      await admin
        .from('safe_mode_session_reports')
        .update({ practice_notified_at: new Date().toISOString() })
        .eq('id', reportId);
      return jsonResponse({ ok: true });
    }
    return jsonResponse({ ok: false, error: 'send-failed' }, 500);
  } catch (e) {
    // Don't crash — return 500 so pg_net logs the failure, but the
    // report row itself is preserved by the RPC's transaction.
    console.error('safe-mode-report error', e);
    return jsonResponse(
      { ok: false, error: String((e as Error)?.message ?? e) },
      500,
    );
  }
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function loadReport(reportId: string) {
  // Pull report + session join so we get the trainer + premises name in
  // one round-trip.
  const { data, error } = await admin
    .from('safe_mode_session_reports')
    .select(
      `
        id, session_id, practice_id, reason, reported_at,
        active_capture_sessions:session_id (
          trainer_id,
          premises:premises_id ( name )
        )
      `,
    )
    .eq('id', reportId)
    .maybeSingle();
  if (error || !data) return null;
  const session = (data as any).active_capture_sessions;
  return {
    id: data.id as string,
    session_id: data.session_id as string,
    practice_id: data.practice_id as string,
    reason: data.reason as string,
    reported_at: data.reported_at as string,
    trainer_id: session?.trainer_id as string | null,
    premises_name: session?.premises?.name as string | null,
  };
}

async function loadPracticeContact(practiceId: string) {
  const { data } = await admin
    .from('practices')
    .select('name, contact_email')
    .eq('id', practiceId)
    .maybeSingle();
  if (!data) return null;
  return {
    practiceName: (data.name as string) ?? '',
    email: (data.contact_email as string | null) ?? '',
  };
}

async function loadPractitioner(trainerId: string | null) {
  if (!trainerId) return null;
  const { data } = await admin
    .from('practitioners')
    .select('first_name, last_name')
    .eq('user_id', trainerId)
    .maybeSingle();
  return data ?? null;
}

async function sendEmail(args: {
  to: string;
  practiceName: string;
  practitionerName: string;
  reason: string;
  reportedAt: string;
  premisesName: string;
}): Promise<boolean> {
  if (!RESEND_API_KEY) {
    console.warn('safe-mode-report: RESEND_API_KEY missing — skipping send');
    return false;
  }
  const subject = `Safe Mode report at ${args.practiceName || 'your practice'}`;
  const headerLine = args.premisesName
    ? `${args.practiceName} · ${args.premisesName}`
    : args.practiceName;

  const html = `
    <div style="font-family:system-ui,-apple-system,sans-serif;background:#F3F4F6;padding:24px;">
      <div style="max-width:560px;margin:0 auto;background:#ffffff;border-radius:12px;padding:24px;">
        <div style="font-family:'Montserrat',sans-serif;font-weight:700;font-size:20px;color:#0F1117;margin-bottom:8px;">
          A bystander reported a Safe Mode session
        </div>
        <div style="font-size:14px;color:#4B5563;margin-bottom:24px;">${escapeHtml(headerLine)}</div>
        <div style="background:#FFF3ED;border-left:3px solid #FF6B35;padding:16px;border-radius:6px;margin-bottom:20px;">
          <div style="font-size:13px;color:#4B5563;margin-bottom:6px;">Reason</div>
          <div style="font-size:15px;color:#0F1117;white-space:pre-wrap;">${escapeHtml(args.reason)}</div>
        </div>
        <table style="width:100%;font-size:14px;color:#0F1117;border-collapse:collapse;">
          <tr>
            <td style="color:#4B5563;padding:4px 0;width:140px;">Practitioner</td>
            <td>${escapeHtml(args.practitionerName)}</td>
          </tr>
          <tr>
            <td style="color:#4B5563;padding:4px 0;">Reported</td>
            <td>${escapeHtml(args.reportedAt)}</td>
          </tr>
        </table>
        <div style="margin-top:24px;font-size:13px;color:#4B5563;line-height:1.55;">
          You're receiving this because your practice is listed as the
          owner of a Safe Mode-enforced premises. Open
          <a href="https://manage.homefit.studio/premises" style="color:#FF6B35;text-decoration:none;font-weight:600;">manage.homefit.studio/premises</a>
          to review and respond. If you don't respond within 48h, the
          homefit team will follow up.
        </div>
      </div>
      <div style="text-align:center;font-size:11px;color:#9CA3AF;margin-top:16px;">
        homefit.studio — Safe Mode transparency
      </div>
    </div>
  `;

  const text = [
    `A bystander reported a Safe Mode session.`,
    `Practice: ${headerLine}`,
    `Practitioner: ${args.practitionerName}`,
    `Reported: ${args.reportedAt}`,
    ``,
    `Reason:`,
    args.reason,
    ``,
    `Review at https://manage.homefit.studio/premises`,
  ].join('\n');

  const body: any = {
    from: `${FROM_NAME} <${FROM_ADDRESS}>`,
    to: [args.to],
    subject,
    html,
    text,
  };
  if (ESCALATION_BCC) body.bcc = [ESCALATION_BCC];

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const text = await response.text().catch(() => '');
    console.warn(
      `safe-mode-report: Resend send failed status=${response.status} body=${text}`,
    );
    return false;
  }
  return true;
}

function jsonResponse(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function escapeHtml(s: string): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) =>
    (
      {
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;',
      } as Record<string, string>
    )[c],
  );
}
