import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

type QueueRow = {
  id: string;
  notification_id: string;
  subscription_id: string | null;
  attempts: number;
  notifications: {
    id: string;
    title: string;
    body: string;
    action_url: string | null;
    priority: string;
  } | null;
  push_subscriptions: {
    id: string;
    endpoint: string;
    p256dh: string;
    auth: string;
  } | null;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:info@lavida.agency";
const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") || "";
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") || "";

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false }
});

if (vapidPublicKey && vapidPrivateKey) {
  webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);
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

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!serviceRoleKey || !vapidPublicKey || !vapidPrivateKey) {
    return Response.json({ error: "Push worker environment is not configured." }, { status: 500 });
  }

  const { data, error } = await admin
    .from("notification_push_queue")
    .select("id,notification_id,subscription_id,attempts,notifications(id,title,body,action_url,priority),push_subscriptions(id,endpoint,p256dh,auth)")
    .eq("status", "queued")
    .order("queued_at", { ascending: true })
    .limit(50);

  if (error) {
    return Response.json({ error: error.message }, { status: 500 });
  }

  let sent = 0;
  let failed = 0;
  let skipped = 0;

  for (const row of (data || []) as QueueRow[]) {
    const notification = row.notifications;
    const subscription = row.push_subscriptions;
    if (!notification || !subscription?.endpoint || !subscription.p256dh || !subscription.auth) {
      skipped += 1;
      await markQueue(row.id, "skipped", "Missing notification or subscription.");
      if (notification?.id) await markNotification(notification.id, "skipped", "Missing notification or subscription.");
      continue;
    }

    const payload = JSON.stringify({
      notification_id: notification.id,
      title: `LAVIDA - ${notification.title}`,
      body: notification.body,
      action_url: notification.action_url || "./marketplace.html#notifications",
      tag: notification.id,
      requireInteraction: notification.priority === "security"
    });

    try {
      await webpush.sendNotification({
        endpoint: subscription.endpoint,
        keys: { p256dh: subscription.p256dh, auth: subscription.auth }
      }, payload);
      sent += 1;
      await markQueue(row.id, "sent");
      await markNotification(notification.id, "sent");
      await admin.from("push_subscriptions").update({ last_used_at: new Date().toISOString(), active: true }).eq("id", subscription.id);
    } catch (sendError) {
      failed += 1;
      const message = sendError instanceof Error ? sendError.message : String(sendError);
      await admin.from("notification_push_queue").update({
        status: row.attempts >= 2 ? "failed" : "queued",
        attempts: Number(row.attempts || 0) + 1,
        last_error: message
      }).eq("id", row.id);
      await markNotification(notification.id, "failed", message);
      if (/410|404/.test(message)) {
        await admin.from("push_subscriptions").update({ active: false }).eq("id", subscription.id);
      }
    }
  }

  return Response.json({ sent, failed, skipped, checked: (data || []).length });
});
