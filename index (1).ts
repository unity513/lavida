import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

// LAVIDA Admin Order Alert Email Worker
// Sends queued admin alert emails. Supports Resend, SendGrid or Postmark.
// Configure with: ADMIN_ALERT_EMAIL_PROVIDER, ADMIN_ALERT_EMAIL_API_KEY,
// ADMIN_ALERT_FROM_EMAIL, ADMIN_ALERT_FROM_NAME, ADMIN_ALERT_REPLY_TO.

type QueueRow = {
  id: string;
  recipient_email: string;
  recipient_name: string | null;
  event_type: string;
  subject: string;
  body_text: string;
  body_html: string | null;
  order_type: string | null;
  order_id: string | null;
  order_reference: string | null;
  attempts: number;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const workerSecret = Deno.env.get("ADMIN_ALERT_WORKER_SECRET") || "";
const providerName = (Deno.env.get("ADMIN_ALERT_EMAIL_PROVIDER") || "resend").toLowerCase();
const providerKey = Deno.env.get("ADMIN_ALERT_EMAIL_API_KEY") || "";
const fromEmail = Deno.env.get("ADMIN_ALERT_FROM_EMAIL") || "info@lavida.agency";
const fromName = Deno.env.get("ADMIN_ALERT_FROM_NAME") || "LAVIDA Connect";
const replyTo = Deno.env.get("ADMIN_ALERT_REPLY_TO") || "";
const maxAttempts = 3;

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false }
});

function isAuthorized(req: Request) {
  if (!workerSecret) return false;
  const bearer = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const explicit = req.headers.get("x-lavida-admin-alert-secret") || "";
  return bearer === workerSecret || explicit === workerSecret;
}

function escapeHtml(value: string) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function textToHtml(text: string) {
  return `<div style="background:#f3f5f8;padding:22px 12px">
    <div style="max-width:620px;margin:auto;background:#fff;border:1px solid #dfe5ee;border-radius:14px;overflow:hidden">
      <div style="background:#03163d;padding:18px 22px">
        <div style="color:#fff;font:900 22px Inter,Arial,sans-serif;letter-spacing:1px">LAVIDA</div>
        <div style="color:#f5b821;font:900 11px Inter,Arial,sans-serif;letter-spacing:2px;text-transform:uppercase;margin-top:3px">New Order Alert</div>
      </div>
      <div style="padding:22px;color:#061433;font:500 14px Inter,Arial,sans-serif;line-height:1.6">
        ${escapeHtml(text).replace(/\n/g, "<br>")}
      </div>
    </div>
  </div>`;
}

function payloadFor(row: QueueRow, toEmail: string) {
  const subject = row.subject || "[LAVIDA Order] New Order";
  const html = row.body_html || textToHtml(row.body_text || "A new order was placed.");
  const text = row.body_text || "A new order was placed.";

  if (providerName === "sendgrid") {
    return {
      url: "https://api.sendgrid.com/v3/mail/send",
      headers: {
        "Authorization": `Bearer ${providerKey}`,
        "Content-Type": "application/json"
      },
      body: {
        personalizations: [{ to: [{ email: toEmail, name: row.recipient_name || undefined }] }],
        from: { email: fromEmail, name: fromName },
        ...(replyTo ? { reply_to: { email: replyTo } } : {}),
        subject,
        content: [
          { type: "text/plain", value: text },
          { type: "text/html", value: html }
        ],
        custom_args: { order_id: row.order_id || "", event_type: row.event_type }
      }
    };
  }

  if (providerName === "postmark") {
    return {
      url: "https://api.postmarkapp.com/email",
      headers: {
        "X-Postmark-Server-Token": providerKey,
        "Content-Type": "application/json",
        "Accept": "application/json"
      },
      body: {
        From: `${fromName} <${fromEmail}>`,
        To: row.recipient_name ? `${row.recipient_name} <${toEmail}>` : toEmail,
        ...(replyTo ? { ReplyTo: replyTo } : {}),
        Subject: subject,
        TextBody: text,
        HtmlBody: html,
        MessageStream: "outbound",
        Metadata: { order_id: row.order_id || "", event_type: row.event_type }
      }
    };
  }

  // Default: Resend
  return {
    url: "https://api.resend.com/emails",
    headers: {
      "Authorization": `Bearer ${providerKey}`,
      "Content-Type": "application/json"
    },
    body: {
      from: `${fromName} <${fromEmail}>`,
      to: row.recipient_name ? `${row.recipient_name} <${toEmail}>` : [toEmail],
      ...(replyTo ? { reply_to: replyTo } : {}),
      subject,
      text,
      html,
      headers: { "X-Entity-Ref-ID": row.order_id || row.id }
    }
  };
}

function providerMessageId(provider: string, result: Record<string, unknown>) {
  if (provider === "postmark") return String(result.MessageID || "");
  if (provider === "sendgrid") return String(result["x-message-id"] || "");
  return String(result.id || "");
}

function isPermanentFailure(status: number) {
  // 4xx other than rate limiting means the request will not succeed on retry.
  return status >= 400 && status < 500 && status !== 429 && status !== 408;
}

async function markQueue(id: string, status: "sent" | "failed" | "skipped", error?: string, messageId?: string) {
  await admin.from("admin_alert_email_queue").update({
    status,
    last_error: error || null,
    provider_message_id: messageId || null,
    sent_at: status === "sent" ? new Date().toISOString() : null
  }).eq("id", id);
}

async function claimQueue(id: string) {
  const { data, error } = await admin
    .from("admin_alert_email_queue")
    .update({ status: "processing", last_error: null })
    .eq("id", id)
    .eq("status", "queued")
    .select("id")
    .maybeSingle();
  if (error) throw new Error(error.message);
  return Boolean(data?.id);
}

async function releaseStaleClaims() {
  const cutoff = new Date(Date.now() - 5 * 60 * 1000).toISOString();
  await admin
    .from("admin_alert_email_queue")
    .update({ status: "queued", last_error: "Previous delivery attempt timed out." })
    .eq("status", "processing")
    .lt("updated_at", cutoff);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!isAuthorized(req)) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }
  if (!supabaseUrl || !serviceRoleKey) {
    return Response.json({ error: "Email worker environment is not configured." }, { status: 500 });
  }
  if (!providerKey) {
    return Response.json({ error: "No email provider API key is configured." }, { status: 500 });
  }

  let limit = 50;
  try {
    const body = await req.json();
    if (Number.isFinite(body?.limit)) limit = Math.max(1, Math.min(100, Number(body.limit)));
  } catch (_error) {}

  await releaseStaleClaims();

  const { data, error } = await admin
    .from("admin_alert_email_queue")
    .select("id,recipient_email,recipient_name,event_type,subject,body_text,body_html,order_type,order_id,order_reference,attempts")
    .eq("status", "queued")
    .order("queued_at", { ascending: true })
    .limit(limit);

  if (error) {
    return Response.json({ error: error.message }, { status: 500 });
  }

  let sent = 0;
  let failed = 0;
  let skipped = 0;

  for (const row of (data || []) as QueueRow[]) {
    if (!(await claimQueue(row.id))) continue;

    if (!row.recipient_email || !/.+@.+\..+/.test(row.recipient_email)) {
      skipped += 1;
      await markQueue(row.id, "skipped", "Recipient email is missing or invalid.");
      continue;
    }

    try {
      const request = payloadFor(row, row.recipient_email);
      const response = await fetch(request.url, {
        method: "POST",
        headers: request.headers as Record<string, string>,
        body: JSON.stringify(request.body)
      });

      const result = await response.json().catch(() => ({}));

      if (!response.ok) {
        const message = JSON.stringify(result).slice(0, 600) || `Provider HTTP ${response.status}`;
        const permanent = isPermanentFailure(response.status) || row.attempts >= maxAttempts;
        failed += 1;
        await admin.from("admin_alert_email_queue").update({
          status: permanent ? "failed" : "queued",
          attempts: Number(row.attempts || 0) + 1,
          last_error: message
        }).eq("id", row.id);
        continue;
      }

      sent += 1;
      await markQueue(row.id, "sent", undefined, providerMessageId(providerName, result as Record<string, unknown>));
    } catch (sendError) {
      const message = sendError instanceof Error ? sendError.message : String(sendError);
      failed += 1;
      await admin.from("admin_alert_email_queue").update({
        status: row.attempts >= maxAttempts ? "failed" : "queued",
        attempts: Number(row.attempts || 0) + 1,
        last_error: message
      }).eq("id", row.id);
    }
  }

  return Response.json({ sent, failed, skipped, checked: (data || []).length, provider: providerName });
});
