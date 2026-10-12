import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const COOLDOWN_SECONDS = 60;
const WINDOW_MINUTES = 15;
const MAX_PAIR_WINDOW = 3;
const MAX_EMAIL_WINDOW = 5;
const MAX_IP_WINDOW = 15;

function json(body: unknown, status = 200, extraHeaders: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, ...extraHeaders }
  });
}

function normalizeEmail(value: unknown) {
  return String(value || "").trim().toLowerCase();
}

function ipFromRequest(req: Request) {
  return (
    req.headers.get("cf-connecting-ip") ||
    req.headers.get("x-real-ip") ||
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    "unknown"
  );
}

async function sha256(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ exists: false }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const salt = Deno.env.get("LAVIDA_RATE_LIMIT_SALT") || serviceRoleKey || "";

  if (!supabaseUrl || !serviceRoleKey || !salt) return json({ exists: false }, 500);

  let email = "";
  try {
    const body = await req.json();
    email = normalizeEmail(body?.email);
  } catch (_error) {
    return json({ exists: false }, 400);
  }

  if (!EMAIL_RE.test(email)) return json({ exists: false }, 400);

  const ip = ipFromRequest(req);
  const userAgent = (req.headers.get("user-agent") || "").slice(0, 300);
  const ipHash = await sha256(`${salt}:ip:${ip}`);
  const emailHash = await sha256(`${salt}:email:${email}`);
  const pairHash = await sha256(`${salt}:pair:${ip}:${email}`);
  const sinceWindow = new Date(Date.now() - WINDOW_MINUTES * 60 * 1000).toISOString();

  const db = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false }
  });

  const countRecent = async (column: "ip_hash" | "email_hash" | "pair_hash", value: string) => {
    const { count, error } = await db
      .from("auth_email_security_events")
      .select("id", { count: "exact", head: true })
      .eq(column, value)
      .in("event_type", ["check", "rate_limited"])
      .gte("created_at", sinceWindow);
    if (error) throw error;
    return count || 0;
  };

  const recordEvent = async (eventType: string, success: boolean, existsResult: boolean | null, metadata = {}) => {
    await db.from("auth_email_security_events").insert({
      event_type: eventType,
      ip_hash: ipHash,
      email_hash: emailHash,
      pair_hash: pairHash,
      exists_result: existsResult,
      success,
      user_agent: userAgent,
      metadata
    });
  };

  try {
    const { data: lastPair } = await db
      .from("auth_email_security_events")
      .select("created_at")
      .eq("pair_hash", pairHash)
      .in("event_type", ["check", "rate_limited"])
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (lastPair?.created_at) {
      const elapsed = Math.floor((Date.now() - new Date(lastPair.created_at).getTime()) / 1000);
      if (elapsed < COOLDOWN_SECONDS) {
        const retryAfter = String(COOLDOWN_SECONDS - elapsed);
        await recordEvent("rate_limited", false, null, { reason: "cooldown" });
        return json({ exists: false }, 429, { "Retry-After": retryAfter });
      }
    }

    const [pairCount, emailCount, ipCount] = await Promise.all([
      countRecent("pair_hash", pairHash),
      countRecent("email_hash", emailHash),
      countRecent("ip_hash", ipHash)
    ]);

    if (pairCount >= MAX_PAIR_WINDOW || emailCount >= MAX_EMAIL_WINDOW || ipCount >= MAX_IP_WINDOW) {
      await recordEvent("rate_limited", false, null, {
        reason: "window_limit",
        pair_count: pairCount,
        email_count: emailCount,
        ip_count: ipCount,
        captcha_recommended: true
      });
      return json({ exists: false }, 429, { "Retry-After": String(COOLDOWN_SECONDS) });
    }

    const { data, error } = await db.rpc("lavida_auth_email_exists", { p_email: email });
    if (error) throw error;

    const exists = Boolean(data);
    await recordEvent("check", true, exists);
    return json({ exists });
  } catch (_error) {
    try {
      await recordEvent("error", false, null);
    } catch (_ignored) {}
    return json({ exists: false }, 500);
  }
});
