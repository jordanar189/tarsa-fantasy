// Sends push notifications via APNs (token-based auth over HTTP/2).
//
// Two modes:
//   • Cron (empty body): processes every push_notifications row that is due —
//     status='scheduled' and (scheduled_at is null OR scheduled_at <= now()).
//     Wired to the dispatch_push_minute cron job.
//   • Direct ({ "notification_id": "<uuid>" }): sends that one row right away.
//     The app calls this on "send now" so there's no up-to-a-minute wait; the
//     cron is the safety net if the direct call fails.
//
// Required Edge Function secrets (Dashboard → Edge Functions → Secrets):
//   APNS_KEY        – full contents of the .p8 auth key (PEM, incl. BEGIN/END)
//   APNS_KEY_ID     – the 10-char Key ID for that .p8
//   APNS_TEAM_ID    – Apple Developer Team ID
//   APNS_BUNDLE_ID  – app bundle id / APNs topic (defaults to the app's id)
// SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are injected by the runtime.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const APNS_KEY       = Deno.env.get("APNS_KEY") ?? "";
const APNS_KEY_ID    = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID   = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.personal.Tarsa-Fantasy";

const APNS_HOST: Record<string, string> = {
    production: "https://api.push.apple.com",
    sandbox:    "https://api.sandbox.push.apple.com",
};

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
});

interface NotificationRow {
    id: string;
    title: string;
    body: string;
    image_url: string | null;
    deep_link: string | null;
    target: string;
    target_user_ids: string[] | null;
}
interface TokenRow { token: string; environment: string }

const SELECT_COLS = "id, title, body, image_url, deep_link, target, target_user_ids";

Deno.serve(async (req: Request) => {
    try {
        if (!APNS_KEY || !APNS_KEY_ID || !APNS_TEAM_ID) {
            return json({ error: "APNs secrets not configured" }, 500);
        }

        let body: { notification_id?: string } = {};
        try { body = await req.json(); } catch { /* empty body → cron mode */ }

        let rows: NotificationRow[] = [];
        if (body.notification_id) {
            const { data } = await supa.from("push_notifications")
                .select(SELECT_COLS)
                .eq("id", body.notification_id)
                .maybeSingle();
            if (data) rows = [data as NotificationRow];
        } else {
            const nowIso = new Date().toISOString();
            const { data } = await supa.from("push_notifications")
                .select(SELECT_COLS)
                .eq("status", "scheduled")
                .or(`scheduled_at.is.null,scheduled_at.lte.${nowIso}`)
                .limit(50);
            rows = (data ?? []) as NotificationRow[];
        }

        let processed = 0;
        for (const n of rows) {
            if (await processNotification(n)) processed += 1;
        }
        return json({ ok: true, processed });
    } catch (err) {
        return json({ error: String(err) }, 500);
    }
});

// Claims a notification (scheduled → sending), resolves its target tokens,
// pushes to each, prunes dead tokens, then records the outcome. Returns false
// if the row was already claimed by a concurrent run.
async function processNotification(n: NotificationRow): Promise<boolean> {
    const { data: claimed } = await supa.from("push_notifications")
        .update({ status: "sending" })
        .eq("id", n.id)
        .eq("status", "scheduled")
        .select("id")
        .maybeSingle();
    if (!claimed) return false;

    try {
        let query = supa.from("device_tokens").select("token, environment");
        if (n.target === "users") {
            const ids = n.target_user_ids ?? [];
            if (ids.length === 0) {
                await finish(n.id, "sent", 0, 0, null);
                return true;
            }
            query = query.in("user_id", ids);
        }
        const { data: tokenData } = await query;
        const tokens: TokenRow[] = (tokenData ?? []) as TokenRow[];
        if (tokens.length === 0) {
            await finish(n.id, "sent", 0, 0, null);
            return true;
        }

        const authToken = await apnsAuthToken();
        let sent = 0, failed = 0;
        const dead: string[] = [];

        const CHUNK = 20;
        for (let i = 0; i < tokens.length; i += CHUNK) {
            const slice = tokens.slice(i, i + CHUNK);
            const results = await Promise.all(slice.map(async (t) => {
                try { return { t, r: await sendToToken(authToken, t, n) }; }
                catch { return { t, r: { ok: false, remove: false } }; }
            }));
            for (const { t, r } of results) {
                if (r.ok) sent += 1;
                else { failed += 1; if (r.remove) dead.push(t.token); }
            }
        }

        if (dead.length) {
            await supa.from("device_tokens").delete().in("token", dead);
        }
        await finish(n.id, "sent", sent, failed, null);
        return true;
    } catch (err) {
        await finish(n.id, "failed", 0, 0, String(err));
        return true;
    }
}

async function finish(
    id: string, status: string, sent: number, failed: number, error: string | null
): Promise<void> {
    await supa.from("push_notifications").update({
        status,
        sent_at: new Date().toISOString(),
        sent_count: sent,
        fail_count: failed,
        error,
    }).eq("id", id);
}

async function sendToToken(
    authToken: string, t: TokenRow, n: NotificationRow
): Promise<{ ok: boolean; remove: boolean }> {
    const host = APNS_HOST[t.environment === "sandbox" ? "sandbox" : "production"];
    const aps: Record<string, unknown> = {
        alert: { title: n.title, body: n.body },
        sound: "default",
    };
    if (n.image_url) aps["mutable-content"] = 1;
    const payload: Record<string, unknown> = { aps };
    if (n.image_url) payload["image_url"] = n.image_url;
    if (n.deep_link) payload["deep_link"] = n.deep_link;

    const resp = await fetch(`${host}/3/device/${t.token}`, {
        method: "POST",
        headers: {
            "authorization": `bearer ${authToken}`,
            "apns-topic": APNS_BUNDLE_ID,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "content-type": "application/json",
        },
        body: JSON.stringify(payload),
    });

    if (resp.status === 200) {
        await resp.body?.cancel();
        return { ok: true, remove: false };
    }
    let reason = "";
    try { reason = ((await resp.json()) as { reason?: string })?.reason ?? ""; }
    catch { /* no body */ }
    const remove = resp.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";
    return { ok: false, remove };
}

// ---- APNs provider token (ES256 JWT, cached ~50 min) ----------------------

let cachedJWT: { token: string; iat: number } | null = null;

async function apnsAuthToken(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (cachedJWT && now - cachedJWT.iat < 3000) return cachedJWT.token;

    const header  = { alg: "ES256", kid: APNS_KEY_ID };
    const payload = { iss: APNS_TEAM_ID, iat: now };
    const signingInput = `${b64urlJSON(header)}.${b64urlJSON(payload)}`;

    const key = await importPrivateKey(APNS_KEY);
    // Web Crypto returns the ECDSA signature in IEEE-P1363 (r‖s) form, which is
    // exactly what JOSE ES256 expects — no DER unwrapping needed.
    const sig = await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        key,
        new TextEncoder().encode(signingInput),
    );
    const token = `${signingInput}.${b64url(new Uint8Array(sig))}`;
    cachedJWT = { token, iat: now };
    return token;
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
    const b64 = pem
        .replace(/-----BEGIN PRIVATE KEY-----/, "")
        .replace(/-----END PRIVATE KEY-----/, "")
        .replace(/\s+/g, "");
    const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    return await crypto.subtle.importKey(
        "pkcs8",
        der.buffer,
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"],
    );
}

function b64urlJSON(obj: unknown): string {
    return b64url(new TextEncoder().encode(JSON.stringify(obj)));
}

function b64url(bytes: Uint8Array): string {
    let s = "";
    for (const b of bytes) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function json(obj: unknown, status = 200): Response {
    return new Response(JSON.stringify(obj), {
        status,
        headers: { "Content-Type": "application/json" },
    });
}
