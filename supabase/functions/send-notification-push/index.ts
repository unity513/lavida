import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

type QueueRow = {
  id: string;
  notification_id: string;
  subscription_id: string | null;
  attempts: number;
  notification: {
    id: string;
    user_id: string | null;
    notification_type: string;
    category: string;
    title: string;
    body: string;
    action_url: string | null;
    priority: string;
    entity_type: string | null;
    entity_id: string | null;
    metadata: Record<string, unknown> | null;
  } | null;
  subscription: {
    id: string;
    endpoint: string;
    p256dh: string;
    auth: string | null;
    auth_key: string | null;
  } | null;
};

type MobileQueueRow = {
  id: string;
  notification_id: string;
  mobile_push_token_id: string | null;
  attempts: number;
  notification: {
    id: string;
    user_id: string | null;
    notification_type: string;
    category: string;
    title: string;
    body: string;
    action_url: string | null;
    priority: string;
    entity_type: string | null;
    entity_id: string | null;
    metadata: Record<string, unknown> | null;
  } | null;
  token: {
    id: string;
    user_id: string;
    fcm_token: string;
    platform: string;
  } | null;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:info@lavida.agency";
const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") || "";
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") || "";
const workerSecret = Deno.env.get("PUSH_WORKER_SECRET") || "";
const firebaseServiceAccountJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "";
const firebaseProjectIdOverride = Deno.env.get("FIREBASE_PROJECT_ID") || "";
let firebaseAccessToken: { token: string; expiresAt: number } | null = null;

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false }
});

if (vapidPublicKey && vapidPrivateKey) {
  webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);
}

function isAuthorized(req: Request) {
  if (!workerSecret) return false;
  const bearer = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const explicit = req.headers.get("x-lavida-push-secret") || "";
  return bearer === workerSecret || explicit === workerSecret;
}

async function markQueue(id: string, status: "sent" | "failed" | "skipped", error?: string) {
  await admin.from("notification_push_queue").update({
    status,
    last_error: error || null,
    sent_at: status === "sent" ? new Date().toISOString() : null
  }).eq("id", id);
}

async function markNotification(id: string, status: "sent" | "failed" | "skipped", error?: string) {
  await admin.from("notifications").update({
    push_status: status,
    push_last_error: error || null
  }).eq("id", id);
}

async function logDelivery(
  notificationId: string,
  userId: string | null,
  channel: "web_push" | "android_fcm",
  destinationRef: string | null,
  status: "queued" | "sent" | "failed" | "skipped",
  providerResponse?: Record<string, unknown>,
  errorMessage?: string
) {
  await admin.from("notification_delivery_log").insert({
    notification_id: notificationId,
    user_id: userId,
    channel,
    destination_ref: destinationRef,
    status,
    provider_response: providerResponse || null,
    error_message: errorMessage || null,
    delivered_at: status === "sent" ? new Date().toISOString() : null
  });
}

function permanentPushFailure(error: unknown, message: string) {
  const detail = error as { statusCode?: number; status?: number; code?: number };
  const status = Number(detail?.statusCode || detail?.status || detail?.code || 0);
  return status === 404 || status === 410 || /\b(404|410)\b/.test(message);
}

function base64Url(input: string | ArrayBuffer) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function pemToArrayBuffer(pem: string) {
  const b64 = pem.replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function getFirebaseAccessToken() {
  if (firebaseAccessToken && firebaseAccessToken.expiresAt > Date.now() + 60000) {
    return firebaseAccessToken.token;
  }
  if (!firebaseServiceAccountJson) return null;

  const account = JSON.parse(firebaseServiceAccountJson.replace(/\\n/g, "\\n"));
  const clientEmail = account.client_email;
  const privateKey = account.private_key;
  if (!clientEmail || !privateKey) return null;

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600
  };
  const unsigned = `${base64Url(JSON.stringify(header))}.${base64Url(JSON.stringify(payload))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const assertion = `${unsigned}.${base64Url(signature)}`;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion
    })
  });
  const body = await response.json();
  if (!response.ok || !body.access_token) {
    throw new Error(body.error_description || body.error || "Could not authenticate with Firebase.");
  }
  firebaseAccessToken = {
    token: body.access_token,
    expiresAt: Date.now() + Math.max(300, Number(body.expires_in || 3600) - 60) * 1000
  };
  return firebaseAccessToken.token;
}

function firebaseProjectId() {
  if (firebaseProjectIdOverride) return firebaseProjectIdOverride;
  if (!firebaseServiceAccountJson) return "";
  try {
    const account = JSON.parse(firebaseServiceAccountJson.replace(/\\n/g, "\\n"));
    return account.project_id || "";
  } catch (_error) {
    return "";
  }
}

function notificationUrl(url: string | null) {
  const fallback = "https://app.lavida.agency/marketplace.html#notifications";
  if (!url) return fallback;
  try {
    return new URL(url, "https://app.lavida.agency/").href;
  } catch (_error) {
    return fallback;
  }
}

function channelFor(category: string) {
  if (category === "games") return "games_events";
  if (category === "marketplace") return "marketplace";
  if (category === "invoice_payment" || category === "order_delivery") return "orders_payments";
  if (category === "service") return "projects_printing";
  return "lavida_updates";
}

async function processWebPush(limit: number) {
  if (!vapidPublicKey || !vapidPrivateKey) {
    return { web_sent: 0, web_failed: 0, web_skipped: 0, web_checked: 0, web_configured: false };
  }

  const { data, error } = await admin
    .from("notification_push_queue")
    .select("id,notification_id,subscription_id,attempts,notification:notifications!notification_push_queue_notification_id_fkey(id,user_id,notification_type,category,title,body,action_url,priority,entity_type,entity_id,metadata),subscription:push_subscriptions!notification_push_queue_subscription_id_fkey(id,endpoint,p256dh,auth,auth_key)")
    .eq("status", "queued")
    .order("queued_at", { ascending: true })
    .limit(limit);

  if (error) {
    throw new Error(error.message);
  }

  let sent = 0;
  let failed = 0;
  let skipped = 0;

  for (const row of (data || []) as QueueRow[]) {
    const notification = row.notification;
    const subscription = row.subscription;
    const authSecret = subscription?.auth || subscription?.auth_key || "";
    if (!notification || !subscription?.endpoint || !subscription.p256dh || !authSecret) {
      skipped += 1;
      await markQueue(row.id, "skipped", "Missing notification or subscription.");
      if (notification?.id) await markNotification(notification.id, "skipped", "Missing notification or subscription.");
      if (notification?.id) await logDelivery(notification.id, notification.user_id, "web_push", subscription?.id || row.subscription_id, "skipped", undefined, "Missing notification or subscription.");
      continue;
    }

    const payload = JSON.stringify({
      notification_id: notification.id,
      title: notification.title || "LAVIDA Connect",
      body: notification.body,
      icon: "/assets/lavida-icon.svg",
      badge: "/assets/lavida-icon.svg",
      url: notificationUrl(notification.action_url),
      type: notification.notification_type,
      category: notification.category,
      entity_type: notification.entity_type,
      entity_id: notification.entity_id,
      metadata: notification.metadata || {},
      action_url: notification.action_url || "./marketplace.html#notifications",
      tag: notification.id,
      requireInteraction: notification.priority === "security"
    });

    try {
      await webpush.sendNotification({
        endpoint: subscription.endpoint,
        keys: { p256dh: subscription.p256dh, auth: authSecret }
      }, payload);
      sent += 1;
      await markQueue(row.id, "sent");
      await markNotification(notification.id, "sent");
      await admin.from("push_subscriptions").update({ last_used_at: new Date().toISOString(), active: true }).eq("id", subscription.id);
      await logDelivery(notification.id, notification.user_id, "web_push", subscription.id, "sent", { provider: "web_push" });
    } catch (sendError) {
      failed += 1;
      const message = sendError instanceof Error ? sendError.message : String(sendError);
      const isPermanent = permanentPushFailure(sendError, message);
      await admin.from("notification_push_queue").update({
        status: isPermanent || row.attempts >= 2 ? "failed" : "queued",
        attempts: Number(row.attempts || 0) + 1,
        last_error: message
      }).eq("id", row.id);
      await markNotification(notification.id, "failed", message);
      await logDelivery(notification.id, notification.user_id, "web_push", subscription.id, "failed", { permanent: isPermanent }, message);
      if (isPermanent) {
        await admin.from("push_subscriptions").delete().eq("id", subscription.id);
      }
    }
  }

  return { web_sent: sent, web_failed: failed, web_skipped: skipped, web_checked: (data || []).length, web_configured: true };
}

function permanentFcmFailure(status: number, body: Record<string, unknown>) {
  const error = body.error as { status?: string; message?: string } | undefined;
  const text = `${error?.status || ""} ${error?.message || ""}`;
  return status === 404 || /UNREGISTERED|NOT_FOUND|registration token is not a valid/i.test(text);
}

async function markMobileQueue(id: string, status: "sent" | "failed" | "skipped", error?: string) {
  await admin.from("notification_mobile_push_queue").update({
    status,
    last_error: error || null,
    sent_at: status === "sent" ? new Date().toISOString() : null
  }).eq("id", id);
}

async function processAndroidPush(limit: number) {
  const projectId = firebaseProjectId();
  if (!firebaseServiceAccountJson || !projectId) {
    return { android_sent: 0, android_failed: 0, android_skipped: 0, android_checked: 0, android_configured: false };
  }

  const accessToken = await getFirebaseAccessToken();
  if (!accessToken) {
    return { android_sent: 0, android_failed: 0, android_skipped: 0, android_checked: 0, android_configured: false };
  }

  const { data, error } = await admin
    .from("notification_mobile_push_queue")
    .select("id,notification_id,mobile_push_token_id,attempts,notification:notifications!notification_mobile_push_queue_notification_id_fkey(id,user_id,notification_type,category,title,body,action_url,priority,entity_type,entity_id,metadata),token:mobile_push_tokens!notification_mobile_push_queue_mobile_push_token_id_fkey(id,user_id,fcm_token,platform)")
    .eq("status", "queued")
    .order("queued_at", { ascending: true })
    .limit(limit);

  if (error) {
    throw new Error(error.message);
  }

  let sent = 0;
  let failed = 0;
  let skipped = 0;
  const endpoint = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

  for (const row of (data || []) as MobileQueueRow[]) {
    const notification = row.notification;
    const token = row.token;
    if (!notification || !token?.fcm_token) {
      skipped += 1;
      await markMobileQueue(row.id, "skipped", "Missing notification or Android token.");
      if (notification?.id) await markNotification(notification.id, "skipped", "Missing notification or Android token.");
      if (notification?.id) await logDelivery(notification.id, notification.user_id, "android_fcm", token?.id || row.mobile_push_token_id, "skipped", undefined, "Missing notification or Android token.");
      continue;
    }

    const url = notificationUrl(notification.action_url);
    const body = {
      message: {
        token: token.fcm_token,
        notification: {
          title: notification.title || "LAVIDA Connect",
          body: notification.body || "You have a new LAVIDA notification."
        },
        data: {
          notification_id: notification.id,
          notificationId: notification.id,
          type: notification.notification_type || "",
          category: notification.category || "",
          url,
          orderId: notification.entity_type?.includes("order") ? notification.entity_id || "" : "",
          invoiceId: notification.entity_type?.includes("invoice") ? notification.entity_id || "" : "",
          projectId: notification.entity_type?.includes("project") ? notification.entity_id || "" : ""
        },
        android: {
          priority: "high",
          notification: {
            channel_id: channelFor(notification.category),
            icon: "ic_stat_lavida",
            color: "#061433",
            click_action: "OPEN_LAVIDA_CONNECT"
          }
        }
      }
    };

    try {
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify(body)
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) {
        const message = JSON.stringify(result).slice(0, 600) || `FCM HTTP ${response.status}`;
        const isPermanent = permanentFcmFailure(response.status, result);
        failed += 1;
        await admin.from("notification_mobile_push_queue").update({
          status: isPermanent || row.attempts >= 2 ? "failed" : "queued",
          attempts: Number(row.attempts || 0) + 1,
          last_error: message
        }).eq("id", row.id);
        await markNotification(notification.id, "failed", message);
        await logDelivery(notification.id, notification.user_id, "android_fcm", token.id, "failed", result, message);
        if (isPermanent) {
          await admin.from("mobile_push_tokens").update({ active: false, updated_at: new Date().toISOString() }).eq("id", token.id);
        }
        continue;
      }

      sent += 1;
      await markMobileQueue(row.id, "sent");
      await markNotification(notification.id, "sent");
      await admin.from("mobile_push_tokens").update({ last_seen_at: new Date().toISOString(), active: true }).eq("id", token.id);
      await logDelivery(notification.id, notification.user_id, "android_fcm", token.id, "sent", result);
    } catch (sendError) {
      failed += 1;
      const message = sendError instanceof Error ? sendError.message : String(sendError);
      await admin.from("notification_mobile_push_queue").update({
        status: row.attempts >= 2 ? "failed" : "queued",
        attempts: Number(row.attempts || 0) + 1,
        last_error: message
      }).eq("id", row.id);
      await markNotification(notification.id, "failed", message);
      await logDelivery(notification.id, notification.user_id, "android_fcm", token.id, "failed", undefined, message);
    }
  }

  return { android_sent: sent, android_failed: failed, android_skipped: skipped, android_checked: (data || []).length, android_configured: true };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!isAuthorized(req)) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }
  if (!supabaseUrl || !serviceRoleKey || !workerSecret) {
    return Response.json({ error: "Push worker environment is not configured." }, { status: 500 });
  }

  let limit = 50;
  try {
    const body = await req.json();
    if (Number.isFinite(body?.limit)) limit = Math.max(1, Math.min(100, Number(body.limit)));
  } catch (_error) {}

  const [web, android] = await Promise.all([
    processWebPush(limit),
    processAndroidPush(limit)
  ]);

  return Response.json({ ...web, ...android });
});
