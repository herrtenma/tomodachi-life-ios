// Needs `npm run dev` running (port 8788, local R2 and Durable Object): node test/smoke.mjs
const base = process.env.BASE ?? "http://127.0.0.1:8788";
const post = (b) => fetch(base + "/feedback", { method: "POST", body: JSON.stringify(b) }).then(async (r) => [r.status, await r.json()]);
const dev = "test-device-" + Math.random().toString(36).slice(2, 10);
let fails = 0;
const check = (name, ok) => { console.log(ok ? "ok  " : "FAIL", name); if (!ok) fails++; };
check("report accepted", (await post({ device: dev, kind: "bug", message: "hello", log: "line\n" }))[0] === 200);
check("empty idea refused", (await post({ device: dev, kind: "idea", message: " " }))[0] === 400);
check("no device refused", (await post({ kind: "bug", message: "x" }))[0] === 400);
for (let i = 0; i < 4; i++) await post({ device: dev, kind: "crash" });
check("6th report from one device limited", (await post({ device: dev, kind: "crash" }))[0] === 429);
check("admin needs a token", (await fetch(base + "/admin/list")).status === 401);
process.exit(fails ? 1 : 0);
