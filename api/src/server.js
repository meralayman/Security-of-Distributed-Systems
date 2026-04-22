import express from "express";
import jwt from "jsonwebtoken";
import { randomUUID } from "crypto";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import swaggerUi from "swagger-ui-express";
import {
  pool,
  insertAudit,
  insertState,
  fetchStatesForRequest,
  fetchAuditsForRequest,
  fetchRecentAuditRows,
  fetchRecentStateRows,
} from "./db.js";
import { publishTask } from "./mq.js";
import { RequestState } from "./states.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const openApiSpec = JSON.parse(readFileSync(join(__dirname, "openapi.json"), "utf8"));

const SERVICE_NAME = process.env.SERVICE_NAME || "api";
const JWT_SECRET = process.env.JWT_SECRET || "dev-jwt-secret-change-in-production";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&gt;")
    .replace(/"/g, "&quot;");
}

const app = express();
app.disable("x-powered-by");
app.use(express.json());

app.get("/openapi.json", (_req, res) => res.json(openApiSpec));
app.use("/docs", swaggerUi.serve, swaggerUi.setup(openApiSpec));

app.use((_req, res, next) => {
  res.setHeader("X-API-Instance", SERVICE_NAME);
  next();
});

function requireJwt(req, res, next) {
  const h = req.headers.authorization;
  if (!h || !h.toLowerCase().startsWith("bearer ")) {
    return res.status(401).json({ detail: "Missing or invalid Authorization header" });
  }
  const token = h.slice(7).trim();
  try {
    req.claims = jwt.verify(token, JWT_SECRET, { algorithms: ["HS256"] });
    return next();
  } catch {
    return res.status(401).json({ detail: "Invalid or expired token" });
  }
}

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: SERVICE_NAME });
});

/** Liveness — process up (bonus §17). */
app.get("/health/live", (_req, res) => {
  res.json({ status: "ok", live: true, service: SERVICE_NAME });
});

/** Readiness — Postgres reachable (bonus §17). */
app.get("/health/ready", async (_req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "ok", ready: true, service: SERVICE_NAME });
  } catch {
    res.status(503).json({ status: "unavailable", ready: false, service: SERVICE_NAME });
  }
});

/** Request lifecycle from DB (bonus §17). */
app.get("/status/:requestId", requireJwt, async (req, res) => {
  const rid = req.params.requestId;
  if (!UUID_RE.test(rid)) {
    return res.status(400).json({ detail: "requestId must be a UUID" });
  }
  try {
    const [states, audits] = await Promise.all([fetchStatesForRequest(rid), fetchAuditsForRequest(rid)]);
    if (states.length === 0 && audits.length === 0) {
      return res.status(404).json({ detail: "Unknown request id" });
    }
    const currentState = states.length ? states[states.length - 1].state : null;
    const apiRows = states.filter((s) => String(s.service_name).startsWith("api"));
    res.json({
      requestId: rid,
      currentState,
      apiInstance: apiRows.length ? apiRows[apiRows.length - 1].service_name : null,
      states,
      audits,
    });
  } catch {
    return res.status(500).json({ detail: "Internal error" });
  }
});

/** Simple HTML tables over recent DB rows (bonus §17); requires JWT. */
app.get("/dashboard", requireJwt, async (_req, res) => {
  try {
    const audits = await fetchRecentAuditRows(35);
    const states = await fetchRecentStateRows(35);
    const rowsA = audits
      .map(
        (r) =>
          `<tr><td>${escapeHtml(r.logged_at)}</td><td>${escapeHtml(r.service_name)}</td><td>${escapeHtml(r.request_id)}</td><td>${escapeHtml(r.action_performed)}</td><td>${escapeHtml(r.status)}</td><td>${escapeHtml(r.source)}</td></tr>`
      )
      .join("");
    const rowsS = states
      .map(
        (r) =>
          `<tr><td>${escapeHtml(r.logged_at)}</td><td>${escapeHtml(r.request_id)}</td><td>${escapeHtml(r.state)}</td><td>${escapeHtml(r.service_name)}</td></tr>`
      )
      .join("");
    const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Audit dashboard</title>
<style>body{font-family:system-ui,sans-serif;margin:16px;background:#111;color:#eee;} table{border-collapse:collapse;width:100%;margin-bottom:24px;} th,td{border:1px solid #444;padding:6px 8px;text-align:left;} th{background:#222}</style></head><body>
<h1>Recent audit_logs</h1><table><thead><tr><th>logged_at</th><th>service</th><th>request_id</th><th>action</th><th>status</th><th>source</th></tr></thead><tbody>${rowsA}</tbody></table>
<h1>Recent request_states</h1><table><thead><tr><th>logged_at</th><th>request_id</th><th>state</th><th>service</th></tr></thead><tbody>${rowsS}</tbody></table>
<p style="opacity:.7">JWT required (Authorization: Bearer …). Open via curl or a client that sends the header.</p></body></html>`;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.send(html);
  } catch {
    res.status(500).send("Internal error");
  }
});

app.post("/auth/token", (req, res) => {
  const { username, password } = req.body || {};
  if (username !== "demo" || password !== "demo") {
    return res.status(401).json({ detail: "Invalid credentials" });
  }
  const access_token = jwt.sign({ sub: "demo-client" }, JWT_SECRET, {
    algorithm: "HS256",
    expiresIn: "60m",
  });
  return res.json({
    access_token,
    token_type: "bearer",
    expires_in: 3600,
  });
});

app.post("/task", requireJwt, async (req, res) => {
  const rawXff = req.headers["x-forwarded-for"];
  const xfwdStr = Array.isArray(rawXff) ? rawXff.join(", ") : rawXff;
  const clientHint = xfwdStr ? { x_forwarded_for: xfwdStr } : {};

  let bodyPayload = req.body?.payload;
  if (bodyPayload === undefined || bodyPayload === null) {
    bodyPayload = {};
  }
  if (typeof bodyPayload !== "object" || Array.isArray(bodyPayload)) {
    return res.status(422).json({ detail: "payload must be a JSON object" });
  }

  const requestId = randomUUID();
  const client = await pool.connect();

  try {
    await client.query("BEGIN");

    await insertState(client, {
      requestId,
      state: RequestState.RECEIVED,
      serviceName: SERVICE_NAME,
      metadata: { endpoint: "/task", ...clientHint },
    });
    await insertAudit(client, {
      serviceName: SERVICE_NAME,
      requestId,
      actionPerformed: "Task request received",
      status: "success",
      source: "client",
      detail: { endpoint: "/task" },
    });

    await insertState(client, {
      requestId,
      state: RequestState.AUTHENTICATED,
      serviceName: SERVICE_NAME,
      metadata: { subject: req.claims?.sub },
    });
    await insertAudit(client, {
      serviceName: SERVICE_NAME,
      requestId,
      actionPerformed: "JWT validated",
      status: "success",
      source: "client",
      detail: { subject: req.claims?.sub },
    });

    try {
      await publishTask({
        requestId,
        payload: bodyPayload,
        serviceName: SERVICE_NAME,
      });
    } catch (err) {
      await insertState(client, {
        requestId,
        state: RequestState.FAILED,
        serviceName: SERVICE_NAME,
        metadata: { stage: "publish", error: String(err) },
      });
      await insertAudit(client, {
        serviceName: SERVICE_NAME,
        requestId,
        actionPerformed: "Failed to publish task to RabbitMQ",
        status: "failure",
        source: "service",
        detail: { error: String(err) },
      });
      await client.query("COMMIT");
      return res.status(502).json({ detail: "Message broker unavailable" });
    }

    const queue = process.env.TASK_QUEUE || "tasks_queue";
    await insertState(client, {
      requestId,
      state: RequestState.QUEUED,
      serviceName: SERVICE_NAME,
      metadata: { queue },
    });
    await insertAudit(client, {
      serviceName: SERVICE_NAME,
      requestId,
      actionPerformed: "Task message published to RabbitMQ",
      status: "success",
      source: "service",
      detail: { queue },
    });

    await client.query("COMMIT");
    return res.json({
      requestId,
      handledBy: SERVICE_NAME,
      status: "queued",
    });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error("[POST /task]", err);
    try {
      await client.query("ROLLBACK");
    } catch (rbErr) {
      // eslint-disable-next-line no-console
      console.error("[POST /task] ROLLBACK failed", rbErr);
    }
    const expose =
      process.env.API_DEBUG_ERRORS === "true" || process.env.NODE_ENV === "development";
    return res.status(500).json({
      detail: expose ? String(err?.message || err) : "Internal error",
    });
  } finally {
    client.release();
  }
});

const port = Number(process.env.PORT || 8000);
app.listen(port, "0.0.0.0", () => {
  // eslint-disable-next-line no-console
  console.log(`${SERVICE_NAME} listening on ${port}`);
});
