// Feedback endpoint. POST /feedback takes one JSON report from the app; admin routes (Bearer ADMIN_TOKEN) list, read and delete them.
export interface Env {
  REPORTS: R2Bucket;
  LIMITS: DurableObjectNamespace;
  ADMIN_TOKEN?: string;
}

// Limits (per UTC day). A report is small, but R2 and the Workers plan aren't free past their allowance.
const PER_DEVICE = 5, PER_IP = 12, PER_DAY = 400;
const MAX_BODY = 400_000, MAX_MESSAGE = 2000, MAX_LOG = 300_000;
const KINDS = ["crash", "bug", "idea"];

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const clean = (v: unknown, max: number) => (typeof v === "string" ? v.slice(0, max) : "");

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname.startsWith("/admin/")) return admin(req, url, env);
    if (url.pathname !== "/feedback" || req.method !== "POST") return json(404, { ok: false, error: "not found" });

    const len = Number(req.headers.get("content-length") ?? "0");
    if (len > MAX_BODY) return json(413, { ok: false, error: "too large" });
    let b: any;
    try {
      const text = await req.text();
      if (text.length > MAX_BODY) return json(413, { ok: false, error: "too large" });
      b = JSON.parse(text);
    } catch {
      return json(400, { ok: false, error: "bad json" });
    }
    const device = clean(b.device, 64).replace(/[^A-Za-z0-9-]/g, "");
    const kind = KINDS.includes(b.kind) ? b.kind : "bug";
    const message = clean(b.message, MAX_MESSAGE);
    if (device.length < 8) return json(400, { ok: false, error: "no device id" });
    if (!message.trim() && kind !== "crash") return json(400, { ok: false, error: "empty message" });

    // Counted before storing: one call to the single Limits object.
    const ip = req.headers.get("cf-connecting-ip") ?? "unknown";
    const day = new Date().toISOString().slice(0, 10);
    const lim = env.LIMITS.get(env.LIMITS.idFromName("limits"));
    const r = await lim.fetch("https://limits/hit", { method: "POST", body: JSON.stringify({ day, device, ip, perDevice: PER_DEVICE, perIp: PER_IP, perDay: PER_DAY }) });
    const verdict = (await r.json()) as { ok: boolean; reason?: string };
    if (!verdict.ok) return json(429, { ok: false, error: "limit", reason: verdict.reason });

    const report = {
      received: new Date().toISOString(),
      kind,
      message,
      contact: clean(b.contact, 200),
      device,
      app: clean(b.app, 40),
      os: clean(b.os, 40),
      model: clean(b.model, 40),
      slot: clean(b.slot, 20),
      log: clean(b.log, MAX_LOG),
    };
    const key = `reports/${day}/${Date.now()}-${kind}-${device.slice(0, 8)}.json`;
    await env.REPORTS.put(key, JSON.stringify(report), { httpMetadata: { contentType: "application/json" } });
    return json(200, { ok: true });
  },
};

async function admin(req: Request, url: URL, env: Env): Promise<Response> {
  const auth = req.headers.get("authorization") ?? "";
  if (!env.ADMIN_TOKEN || auth !== `Bearer ${env.ADMIN_TOKEN}`) return json(401, { ok: false, error: "unauthorized" });
  if (url.pathname === "/admin/list") {   // ?prefix=reports/2026-10-23/  &cursor=
    const l = await env.REPORTS.list({ prefix: url.searchParams.get("prefix") ?? "reports/", cursor: url.searchParams.get("cursor") ?? undefined, limit: 200 });
    return json(200, { ok: true, keys: l.objects.map((o) => ({ key: o.key, size: o.size })), cursor: l.truncated ? l.cursor : null });
  }
  const key = url.searchParams.get("key") ?? "";
  if (!key.startsWith("reports/")) return json(400, { ok: false, error: "bad key" });
  if (url.pathname === "/admin/get") {
    const o = await env.REPORTS.get(key);
    return o ? new Response(o.body, { headers: { "content-type": "application/json" } }) : json(404, { ok: false, error: "not found" });
  }
  if (url.pathname === "/admin/delete" && req.method === "DELETE") {
    await env.REPORTS.delete(key);
    return json(200, { ok: true });
  }
  return json(404, { ok: false, error: "not found" });
}

// One object counts every hit: day|device, day|ip and day|all. Old days are dropped on the way.
export class Limits {
  constructor(private state: DurableObjectState) {}
  async fetch(req: Request): Promise<Response> {
    const { day, device, ip, perDevice, perIp, perDay } = (await req.json()) as Record<string, any>;
    const s = this.state.storage;
    const keys = [`${day}|d|${device}`, `${day}|i|${ip}`, `${day}|all`];
    const caps = [perDevice, perIp, perDay];
    const reasons = ["too many reports from this device today", "too many reports from this network today", "the inbox is full today"];
    const have = await s.get<number>(keys);
    for (let i = 0; i < 3; i++) if ((have.get(keys[i]) ?? 0) >= caps[i]) return Response.json({ ok: false, reason: reasons[i] });
    for (let i = 0; i < 3; i++) await s.put(keys[i], (have.get(keys[i]) ?? 0) + 1);
    // Housekeeping once per day: forget earlier days.
    if (!(await s.get(`swept|${day}`))) {
      await s.put(`swept|${day}`, 1);
      const all = await s.list<number>();
      const old = [...all.keys()].filter((k) => !k.startsWith(day) && !k.startsWith(`swept|${day}`));
      if (old.length) await s.delete(old.slice(0, 128));
    }
    return Response.json({ ok: true });
  }
}
