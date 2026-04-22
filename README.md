# Secure Distributed System (Observability + Security Lab)

End-to-end stack: **Nginx** (HTTPS, load balancing, rate limiting) → **three API replicas** (`api1`–`api3`, **Node.js** + Express + JWT) → **RabbitMQ** → **worker** (**Node.js**, HMAC verification) → **PostgreSQL** (audit logs + request state history). Orchestrated with **Docker Compose**.

## Project layout

| Path | Purpose |
|------|---------|
| `api/` | HTTP API (`src/server.js`), JWT, DB audit, RabbitMQ publish |
| `worker/` | Queue consumer (`src/worker.js`), HMAC verify, DB audit |
| `nginx/` | TLS gateway, load balancer, rate limit |
| `db/` | `init.sql` schema (mounted into Postgres) |

## Prerequisites
- Docker Desktop (Compose v2)
- `curl` (Windows 10+ includes it)
- Optional: Wireshark for the MITM / TLS capture portion

## Quick start (HTTPS / production-style)

```powershell
cd c:\Users\User\Desktop\secure-distributed-system
docker compose up --build -d
```

- HTTPS gateway: `https://localhost/` (self-signed cert baked into the Nginx image; use `curl -k`)
- API docs (Swagger UI): `https://localhost/docs` (accept the certificate warning in the browser)
- RabbitMQ management UI: `http://localhost:15672` (default `guest` / `guest` unless overridden in `.env`)

### Worker service (assignment)

| Responsibility | Implementation |
|----------------|----------------|
| **Consume from RabbitMQ** | **`worker/src/worker.js`** — **`ch.consume(TASK_QUEUE, …)`** with **`prefetch(1)`**. |
| **Validate service identity** | Each message includes **`internal_token`**: hex **HMAC-SHA256** over `request_id`, canonical JSON **`payload`**, and **`service`**, using shared secret **`INTERNAL_SERVICE_TOKEN`** (same value as API). The **secret is never** placed in the message—only the proof. Worker recomputes HMAC and compares with **`crypto.timingSafeEqual`** (`worker/src/sign.js`). |
| **Reject if invalid** | On mismatch: insert **`FAILED`** + audit, **no** `CONSUMED`/`PROCESSED`, message **ack** (bad messages are not requeued forever). |
| **Log CONSUMED** | After verification, before processing. |
| **Process task (dummy)** | **`setTimeout` 50 ms** then build result `{ echo: payload, handled_by }`. |
| **Log PROCESSED** | After dummy processing succeeds. |
| **Log FAILED on error** | **`catch`** path inserts **`FAILED`** + audit (invalid token path also **`FAILED`**). |

The API builds **`internal_token`** in **`api/src/mq.js`**; the worker verifies before any **`CONSUMED`** row (`worker/src/worker.js`).

### Nginx gateway (assignment)

| Must implement | Where |
|----------------|--------|
| **Reverse proxy** | **`location /`** → **`proxy_pass http://api_cluster`** (`nginx/nginx.conf`) |
| **Load balancing** | **`upstream api_cluster`** with **`api1:8000`**, **`api2:8000`**, **`api3:8000`** (default round-robin) |
| **Rate limiting (per IP)** | **`limit_req_zone $binary_remote_addr`** … **`limit_req zone=api_limit`** on HTTPS `location /` |
| **Return 429 when exceeded** | **`limit_req_status 429`** |
| **HTTPS** | **`listen 443 ssl`**, **`ssl_certificate`**, **`ssl_certificate_key`**, TLS 1.2+ |
| **SSL certificate** | Generated at **image build** in **`nginx/Dockerfile`** (`openssl` → **`/etc/nginx/certs/cert.pem`** + **`key.pem`**, self-signed `CN=localhost`) |
| **HTTP → HTTPS redirect** | **`listen 80`** server block → **`return 301 https://$host$request_uri`** |

Browser / client URL: **`https://localhost/`** (port **443**). Plain **`http://localhost/`** on port **80** redirects to HTTPS. Use **`curl -k`** for the self-signed cert.

### RabbitMQ configuration (assignment)

| Requirement | Implementation |
|-------------|------------------|
| **Broker runs in Docker** | Service **`rabbitmq`** in **`docker-compose.yml`** (`rabbitmq:3-management-alpine`). Ports **5672** (AMQP), **15672** (management UI). |
| **Named queue** | **`tasks_queue`** — env **`TASK_QUEUE`** (same value on **`api1`–`api3`** and **`worker`**). API publishes here; worker consumes here. |
| **API sends messages** | **`api/src/mq.js`** → `publishTask()` uses **`sendToQueue`** after **`assertQueue`**. |
| **Durable queue** | **`assertQueue(queue, { durable: true })`** in API and worker — queue metadata survives broker restart. |
| **Persistent messages** | **`sendToQueue(..., { persistent: true })`** — messages are written to disk when the queue is durable (survive broker restart under normal conditions). |

In the management UI (**`http://localhost:15672`**), open **Queues** and select **`tasks_queue`** to verify publishers/consumers and message rates.

### Multiple API instances (assignment)

| Requirement | How this repo implements it |
|-------------|------------------------------|
| **≥ 3 replicas** (`api1`, `api2`, `api3`) | **`docker-compose.yml`** defines three services **`api1`**, **`api2`**, **`api3`**, each **`build: ./api`** with a different **`SERVICE_NAME`** (`api1` / `api2` / `api3`). |
| **Independent handling** | Each runs as its **own container** with its own Node process on port **8000**. **Nginx** load-balances with **`upstream api_cluster`** → `api1:8000`, `api2:8000`, `api3:8000` (see **`nginx/nginx.conf`**). |
| **Identify itself in the response** | **`POST /task`** returns **`handledBy`** = that replica’s name. **`GET /health`** returns **`service`**. Response header **`X-API-Instance`** is always set to the same value as **`handledBy`** / **`service`**. |
| **Log with its own service name** | Every **`audit_logs`** and **`request_states`** insert uses **`service_name: SERVICE_NAME`** from the env var (`api1`, `api2`, or `api3`). |

**Quick proof:** call `GET https://localhost/health` or `POST /task` several times and watch **`handledBy`** / **`X-API-Instance`** rotate across **`api1`**, **`api2`**, **`api3`**.

### Full request flow (assignment §9 — must match exactly)

End-to-end order implemented in this repo:

1. **Client sends HTTPS request** → Browser/`curl -k` to **`https://localhost/...`** (TLS terminated by Nginx).
2. **Nginx forwards to one API instance** → **`proxy_pass http://api_cluster`** picks **`api1`** / **`api2`** / **`api3`** (round-robin).
3. **API — validates JWT** → **`requireJwt`** middleware on **`POST /task`** (`api/src/server.js`); invalid → **401**, handler never runs (no Request ID yet).
4. **API — generates Request ID** → **`randomUUID()`** in handler (`requestId`); same UUID in DB + RabbitMQ + worker.
5. **API — logs RECEIVED** → **`insertState(..., RECEIVED)`** (+ audit).
6. **API — logs AUTHENTICATED** → **`insertState(..., AUTHENTICATED)`** (+ audit).
7. **API sends task to RabbitMQ** → **`publishTask()`** in **`api/src/mq.js`** → **`tasks_queue`**.
8. **API — logs QUEUED** → **`insertState(..., QUEUED)`** (+ audit), then HTTP **200** JSON **`{ requestId, handledBy, status: "queued" }`**.
9. **Worker — consumes task** → **`ch.consume`** delivers payload to **`processMessage`** (`worker/src/worker.js`).
10. After **internal_token** verification: **Worker — logs CONSUMED** → **`insertState(..., CONSUMED)`**.
11. **Worker — processes task** → dummy delay + result object.
12. **Worker — logs PROCESSED** → **`insertState(..., PROCESSED)`**.

*(Failure paths: invalid JWT stops at step 3; broker publish failure logs **FAILED** and **502**; invalid **internal_token** logs **FAILED** without CONSUMED/PROCESSED; runtime errors log **FAILED**.)*

### Audit logging requirements (assignment §10)

Every **`audit_logs`** row carries the six mandatory fields:

| Requirement | PostgreSQL column | Notes |
|---------------|-------------------|--------|
| **Timestamp** | **`logged_at`** | **`TIMESTAMPTZ`**; each insert sets **`logged_at = NOW()`** (`api/src/db.js`, **`worker/src/worker.js`** `insertAudit`). |
| **Service name** | **`service_name`** | Replica/worker identity (`api1` … `api3`, **`worker`**). |
| **Request ID** | **`request_id`** | Same UUID end-to-end for one `/task`. |
| **Action performed** | **`action_performed`** | Short human-readable description (e.g. “JWT validated”, “Task consumed from RabbitMQ”). |
| **Status** | **`status`** | **`success`** or **`failure`** (`CHECK` in **`db/init.sql`**). |
| **Source** | **`source`** | **`client`** (caller-facing API actions) vs **`service`** (broker/internal paths). |

Optional **`detail`** (`JSONB`) holds structured context and is not part of the six core fields. Schema: **`db/init.sql`** (`audit_logs`).

### Testing requirements (assignment §11)

Automated checks live in **`scripts/functional-tests.ps1`**. From the repo root (with **`docker compose up --build -d`** already healthy):

```powershell
.\scripts\functional-tests.ps1
```

Use **`$env:BASE_URL = "http://localhost"`** when running the **HTTP-only** compose file so curl skips TLS (`-k` is applied only for `https://` URLs).

| Functional test | What the script verifies |
|-------------------|--------------------------|
| **Normal request works** | Demo token + **`POST /task`** → **200**, **`status: queued`**, request id + handler in JSON (supports both **`requestId`/`handledBy`** and legacy **`request_id`/`instance`** response shapes). |
| **Load balancing** | **`GET /health`** via Nginx **36×** → at least **two** distinct **`X-API-Instance`** values (`api1`–`api3`). |
| **Unauthorized → 401** | **`POST /task`** without JWT → **401** (runs **before** the heavy `/health` bursts so Nginx **`limit_req`** does not mask 401 with **429**). |
| **Rate limiting → 429** | Parallel **`/health`** burst → at least one **429**. |
| **Messages flow through RabbitMQ** | RabbitMQ management API **`GET /api/queues`** — queue **`tasks_queue`** (or legacy **`tasks`**) exists with a **consumer** (worker). Align **`TASK_QUEUE`** in **`docker-compose.yml`** with the assignment name **`tasks_queue`** and rebuild if your broker still shows only **`tasks`**. |
| **Worker processes tasks** | Poll Postgres until **`request_states`** contains **`PROCESSED`** for the **`request_id`** from step 1. |
| **Logs stored in database** | **`audit_logs`** has multiple rows for that **`request_id`** (API + worker path). |

If **steps 6–7 fail** (**no PROCESSED**, only about **three** **`audit_logs`** rows): the API queued the task, but the **worker** did not complete **`CONSUMED`** / **`PROCESSED`**.

1. **`docker compose ps`** — **`worker`** must be **running** (not **Exited**).
2. **`docker compose logs worker --tail 100`** — crashes, connection errors, or **`PRECONDITION_FAILED`** on **`queue.declare`** (often **DLX**: leave **`ENABLE_TASK_DLX`** unset/`false`, or recreate the **`tasks_queue`** definition / broker volume).
3. **`TASK_QUEUE`** must be the **same** on **`api1`–`api3`** and **`worker`** (default **`tasks_queue`**). Mixed names (**`tasks`** vs **`tasks_queue`**) leave messages unread.
4. **`INTERNAL_SERVICE_TOKEN`** must match on **every** API container and **`worker`** (same **`.env`** / compose defaults).
5. **`ECONNREFUSED`** to **`rabbitmq:5672`** in **`docker compose logs worker`** — RabbitMQ was not accepting AMQP yet (startup race). The worker retries the broker connection on boot (**`RABBIT_CONNECT_RETRIES`** / **`RABBIT_CONNECT_DELAY_MS`**). Rebuild and restart: **`docker compose up -d --build worker`**.
6. **`POST /task`** returns **500** — often **`DATABASE_URL`** in **`.env`** points at **`localhost:5433`** (meant for pgAdmin on the host). Inside Docker, Postgres is **`postgres:5432`**. Remove or fix **`DATABASE_URL`** so the host is **`postgres`** (see **`.env.example`**). Check **`docker compose logs api1`** for **`ECONNREFUSED`** / **`password authentication failed`**. Temporarily set **`API_DEBUG_ERRORS=true`** on **`api1`–`api3`** in Compose to see the error message in the JSON **`detail`** field.

The script waits for a RabbitMQ consumer, polls **`PROCESSED`** up to **45** seconds (override: **`.\scripts\functional-tests.ps1 -ProcessedWaitSec 90`**), prints **`docker compose logs worker`** on failure, and **`docker-compose.yml`** sets **`restart: unless-stopped`** on **`worker`** so it comes back after RabbitMQ is ready.

**Light smoke** (manual spot-check): **`scripts/smoke-test.ps1`**.

### Critical requirements (assignment §16 — do not miss)

| Rubric item | Satisfied how | Proof you can show (submission / demo) |
|-------------|----------------|----------------------------------------|
| **Same Request ID across all services** | One UUID from **`randomUUID()`** in **`api/src/server.js`** is returned as **`requestId`**, stored in **`request_states`** / **`audit_logs`**, sent on the broker message as **`request_id`** (**`api/src/mq.js`**), and reused by the worker (**`worker/src/worker.js`**) for the same rows. **`correlation_id`** in **`publishTask`** matches **`request_id`**. | After one **`POST /task`**, run: **`SELECT request_id, state, service_name FROM request_states WHERE request_id = '<uuid>' ORDER BY logged_at;`** — you see **`api1`–`api3`** then **`worker`** with **one** UUID. RabbitMQ message payload uses the same id (management UI / logs). |
| **All states logged in DB** | Lifecycle states **`RECEIVED`**, **`AUTHENTICATED`**, **`QUEUED`**, **`CONSUMED`**, **`PROCESSED`** (and **`FAILED`** on errors) are **`INSERT`**’d into **`request_states`** only (**`db/init.sql`** **`CHECK`** on **`state`**). API: **`api/src/server.js`**; worker: **`worker/src/worker.js`**. | Query **`request_states`** for a completed task: expect **`RECEIVED` → AUTHENTICATED → QUEUED** from an API **`service_name`**, then **`CONSUMED` → PROCESSED** from **`worker`** (or **`FAILED`** where applicable). |
| **3 API instances running** | **`docker-compose.yml`** defines **`api1`**, **`api2`**, **`api3`** as **three separate services**, each **`build: ./api`** with distinct **`SERVICE_NAME`**. | **`docker compose ps`** lists **`api1`**, **`api2`**, **`api3`** **running**. Optional: **`docker compose logs api1`** vs **`api2`** vs **`api3`**. |
| **Load balancing proof** | **`nginx/nginx.conf`** **`upstream api_cluster`** lists **`api1:8000`**, **`api2:8000`**, **`api3:8000`**; **`proxy_pass http://api_cluster`**. | Repeated **`curl -k https://localhost/health -D -`** (or **`scripts/functional-tests.ps1`**) — **`X-API-Instance`** / JSON **`service`** rotates across **`api1`**, **`api2`**, **`api3`**. Screenshot or terminal capture. |
| **Rate limiting proof** | **`limit_req_zone`** + **`limit_req`** + **`limit_req_status 429`** on **`location /`** (**`nginx/nginx.conf`**). | **`scripts/functional-tests.ps1`** asserts at least one **429** under burst; or spam **`/health`** until **429**. Screenshot of **429** response or Nginx access log line. |
| **MITM simulation proof** | **`docker-compose.http-only.yml`** + **`nginx.http-only.conf`** serve **plain HTTP on port 80** (no TLS on that profile) so a local observer (e.g. **Wireshark** on loopback) can see HTTP contents; contrast with **`docker-compose.yml`** HTTPS stack. | README section **“HTTP-only stack (Wireshark …)”**: capture **`http`** filter, show token/body **visible** on HTTP stack; repeat under HTTPS and show **encryption** (no comparable plaintext). Screenshots + short explanation in **`REPORT.md`**. |
| **Logs stored in database (not only console)** | **`insertAudit`** / **`insertState`** write **`audit_logs`** and **`request_states`** (**`api/src/db.js`**, **`worker/src/worker.js`**). **`console.log`** is ancillary only (listener banner, etc.). | **`SELECT * FROM audit_logs WHERE request_id = '<uuid>';`** — multiple rows with **`logged_at`**, **`service_name`**, **`action_performed`**, **`status`**, **`source`**. Same for **`request_states`**. |

### Optional bonus features (assignment §17)

| Bonus | Implementation |
|-------|------------------|
| **`GET /status/:requestId`** | **`api/src/server.js`** — JWT required; returns **`currentState`**, **`states[]`**, **`audits[]`** from Postgres for that UUID. **404** if no rows. |
| **Worker retry** | **`worker/src/worker.js`** — after **`CONSUMED`**, processing runs up to **`WORKER_MAX_RETRIES`** (default **3**) with **`WORKER_RETRY_DELAY_MS`** backoff (default **150** ms × attempt). Final failure → **`FAILED`** + audit “failed after retries”. |
| **Dead-letter queue** | When **`ENABLE_TASK_DLX=true`** (must match on **API + worker**), **`api/src/rabbitmq-setup.js`** / **`worker/src/rabbitmq-setup.js`** declare an exchange **`tasks_dlx`**, queue **`tasks_dead`**, and **`tasks_queue`** with **`x-dead-letter-*`**. Poison / nacked messages (**`nack(..., false, false)`**) route to **`tasks_dead`**. **First-time setup:** set env on both services; if RabbitMQ already created **`tasks_queue`** without DLX args, delete the queue or reset the broker volume before enabling. Default **`ENABLE_TASK_DLX`** is off so existing stacks keep working. |
| **Health endpoints** | **`GET /health`** — lightweight up check. **`GET /health/live`** — process alive. **`GET /health/ready`** — **`SELECT 1`** against Postgres (**503** if DB down). |
| **Simple dashboard** | **`GET /dashboard`** (JWT) — HTML tables of recent **`audit_logs`** and **`request_states`** (dark theme). Use curl with **`Authorization`** or Swagger “Authorize”. |

See **`.env.example`** for **`WORKER_*`**, **`ENABLE_TASK_DLX`**, **`TASK_DEAD_QUEUE`**, etc.

**Examples:**

```powershell
$token = .\scripts\get-demo-token.ps1
curl.exe -k -H "Authorization: Bearer $token" "https://localhost/status/<requestId-from-POST-task>"
curl.exe -k -H "Authorization: Bearer $token" "https://localhost/dashboard" -o dashboard.html
start dashboard.html
```

### `POST /task` — API responsibilities (assignment checklist)

Traffic reaches the API **through Nginx** (`proxy_pass`). The **`POST /task`** handler chain matches steps 3–8 above:

1. **`Authorization` header** — Reads `Bearer <JWT>` (`requireJwt` middleware).
2. **JWT validation** — HS256 with `JWT_SECRET`; **401** if missing/invalid/expired (`requireJwt`).
3. **UUID** — `randomUUID()` assigned as **`request_id`** everywhere (response field **`requestId`**, DB, RabbitMQ).
4. **States** — Inserts **`RECEIVED`**, then **`AUTHENTICATED`** into `request_states`; matching rows in **`audit_logs`**.
5. **RabbitMQ** — Publishes JSON to **`tasks_queue`** including **`internal_token`** (HMAC) and **`service`** (`publishTask` in **`api/src/mq.js`**).
6. **QUEUED** — Inserted after successful publish; **`FAILED`** if broker publish throws (**502**).
7. **JSON response** — `{ requestId, handledBy, status: "queued" }` where **`handledBy`** is the replica name (`SERVICE_NAME`: `api1` | `api2` | `api3`). **`X-API-Instance`** header echoes **`handledBy`**.

### Get a JWT and submit a task

In **PowerShell**, avoid `-d "{\"key\":...}"`: backslash is not bash-style escaping inside double-quoted strings, so `curl.exe` often receives broken JSON.

**Most reliable on Windows:** write UTF-8 **without BOM** to a temp file and let curl read it (avoids “smart quotes” from editors and odd argv encoding):

```powershell
.\scripts\post-task.ps1
```

That script **does not** assign `$token` in your shell (it mints a token internally). If you want `$token` for your own `curl` lines:

```powershell
$token = .\scripts\get-demo-token.ps1
```

**Manual curl + file (same idea as the script):**

```powershell
$auth = New-TemporaryFile
[System.IO.File]::WriteAllText($auth.FullName, '{"username":"demo","password":"demo"}', (New-Object System.Text.UTF8Encoding $false))
$token = (curl.exe -sk https://localhost/auth/token -H "Content-Type: application/json" --data-binary "@$($auth.FullName)" | ConvertFrom-Json).access_token
Remove-Item $auth.FullName

$body = New-TemporaryFile
[System.IO.File]::WriteAllText($body.FullName, '{"payload":{"hello":"world"}}', (New-Object System.Text.UTF8Encoding $false))
curl.exe -sk https://localhost/task -H "Authorization: Bearer $token" -H "Content-Type: application/json" --data-binary "@$($body.FullName)"
Remove-Item $body.FullName
```

**Inline `-d '{...}'` on Windows PowerShell 5.1** is unreliable for nested JSON (you may get `json_invalid` even on one line). Prefer **`--data-binary @file`** or the scripts above.

**Invoke-RestMethod and TLS:** `-SkipCertificateCheck` exists only in **PowerShell 7+** (`pwsh`). On **Windows PowerShell 5.1** (`powershell.exe`), use either `curl.exe` with `-k` and file bodies, or:

```powershell
.\scripts\invoke-task-irm.ps1
```

**PowerShell 7+** (`pwsh`):

```powershell
$token = (Invoke-RestMethod https://localhost/auth/token -Method Post -ContentType application/json -Body '{"username":"demo","password":"demo"}' -SkipCertificateCheck).access_token
Invoke-RestMethod https://localhost/task -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType application/json -Body '{"payload":{"hello":"world"}}' -SkipCertificateCheck
```

**Browser:** open `https://localhost/docs`, accept the self-signed certificate warning, and use “Try it out” on `/auth/token` and `/task`.

Repeat the `/task` call several times and observe **`handledBy`** (`api1`, `api2`, or `api3`) changing as Nginx round-robins across upstreams. The response header **`X-API-Instance`** matches **`handledBy`**.

### Unauthorized request (expect HTTP 401)

```powershell
curl.exe -sk https://localhost/task -H "Content-Type: application/json" -d '{"payload":{}}'
```

### Rate limiting (expect HTTP 429 after sustained traffic)

Nginx uses `limit_req` at **5 requests/second** per client IP with `burst=10`. Example:

```powershell
1..40 | ForEach-Object { curl.exe -sk -o NUL -w "%{http_code} " https://localhost/health }
```

### Inspect audit trail and state machine in PostgreSQL

```powershell
docker compose exec postgres psql -U app -d auditdb -c "SELECT logged_at, service_name, request_id, action_performed, status, source FROM audit_logs ORDER BY id DESC LIMIT 20;"
docker compose exec postgres psql -U app -d auditdb -c "SELECT logged_at, request_id, state, service_name FROM request_states ORDER BY id DESC LIMIT 30;"
```

### pgAdmin 4 (GUI) — connect to the same database

Postgres is published on the host as **`localhost:5433`** → container port `5432` (see `docker-compose.yml` under `postgres.ports`). The API and worker **do not** use that port; inside Docker they connect with hostname **`postgres`** and the internal port **`5432`** via `DATABASE_URL` (see below).

1. Start the stack: `docker compose up -d`
2. In pgAdmin: **Register → Server**
   - **General → Name:** anything (e.g. `secure-distributed-system`)
   - **Connection → Host:** `localhost`
   - **Port:** `5433` (or the value you set in `.env` as `POSTGRES_HOST_PORT`)
   - **Maintenance database:** `auditdb`
   - **Username:** `app` (or your `POSTGRES_USER`)
   - **Password:** `changeme` (or your `POSTGRES_PASSWORD`)
3. **Save** (store password if you like). Expand **Servers → Databases → auditdb → Schemas → public → Tables** to browse `audit_logs` and `request_states`.

**Create tables manually in pgAdmin (if you ever need to):** open **Tools → Query Tool** on database `auditdb` and run the same script as in the repo file `db/init.sql` (full SQL below). Normally you **do not** need this: the first `docker compose up` already runs `init.sql` from the container mount.

```sql
-- Copy of db/init.sql — run in pgAdmin Query Tool on database `auditdb` only if tables are missing

CREATE TABLE IF NOT EXISTS audit_logs (
    id                  BIGSERIAL PRIMARY KEY,
    logged_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    service_name        VARCHAR(64) NOT NULL,
    request_id          UUID NOT NULL,
    action_performed    VARCHAR(256) NOT NULL,
    status              VARCHAR(16) NOT NULL CHECK (status IN ('success', 'failure')),
    source              VARCHAR(32) NOT NULL CHECK (source IN ('client', 'service')),
    detail              JSONB
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_request_id ON audit_logs (request_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_logged_at ON audit_logs (logged_at);

CREATE TABLE IF NOT EXISTS request_states (
    id              BIGSERIAL PRIMARY KEY,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    request_id      UUID NOT NULL,
    state           VARCHAR(32) NOT NULL CHECK (
        state IN (
            'RECEIVED', 'AUTHENTICATED', 'QUEUED', 'CONSUMED', 'PROCESSED', 'FAILED'
        )
    ),
    service_name    VARCHAR(64) NOT NULL,
    metadata        JSONB
);

CREATE INDEX IF NOT EXISTS idx_request_states_request_id ON request_states (request_id);
CREATE INDEX IF NOT EXISTS idx_request_states_logged_at ON request_states (logged_at);
```

### Where the app connects to Postgres (in source code)

| Component | File | How |
|-----------|------|-----|
| API (api1–api3) | `api/src/db.js` | `new pg.Pool({ connectionString: process.env.DATABASE_URL })` |
| Worker | `worker/src/worker.js` | `new pg.Pool({ connectionString: process.env.DATABASE_URL })` |
| Compose wiring | `docker-compose.yml` | Sets `DATABASE_URL` for `api*` and `worker` to `postgresql://app:changeme@postgres:5432/auditdb` (host **`postgres`** is the Docker service name, **not** `localhost`) |

pgAdmin uses **`localhost:5433`** only because it runs **on your machine** outside Docker; the Node containers use **`postgres:5432`** on the Docker network.

## HTTP-only stack (Wireshark / “MITM visibility” lab)

Use the **standalone** compose file so port **80** is plain HTTP (no TLS on Nginx). Stop the HTTPS stack first to avoid port conflicts.

```powershell
docker compose down
docker compose -f docker-compose.http-only.yml up --build -d
```

Then capture on the loopback interface in Wireshark, filter `http`, and repeat the token + `/task` calls against `http://localhost/...` (no `-k`). Headers, JWT, and JSON bodies appear in cleartext—this is intentional for the assignment contrast with HTTPS.

Return to the secure path:

```powershell
docker compose -f docker-compose.http-only.yml down
docker compose up --build -d
```

## Custom TLS certificates (optional)

The default HTTPS image generates a self-signed certificate at build time. To supply your own PEM files, adjust `nginx/Dockerfile` to `COPY` your `cert.pem` / `key.pem`, or mount them at run time and point `ssl_certificate` / `ssl_certificate_key` in `nginx/nginx.conf` accordingly.

## Environment variables

Copy `.env.example` to `.env` and set strong secrets for anything beyond a local demo (`JWT_SECRET`, `INTERNAL_SERVICE_TOKEN`, `POSTGRES_*`, `RABBITMQ_URL`).

## Architecture summary

| Layer        | Role |
|-------------|------|
| Nginx       | TLS termination, HTTP→HTTPS redirect, upstream LB, `limit_req` |
| API ×3      | Node (Express): JWT on `/task`, UUID `request_id`, audit + state rows, signed RabbitMQ message |
| RabbitMQ    | Durable **`tasks_queue`** (see §6 below) |
| Worker      | Verifies HMAC (`INTERNAL_SERVICE_TOKEN`); states `CONSUMED`, `PROCESSED`, or `FAILED` |
| PostgreSQL| `audit_logs` + `request_states` (see `db/init.sql`) |

### State tracking (mandatory)

Only these **`request_states.state`** values are allowed (enforced in **`db/init.sql`** with a `CHECK` constraint, and in code via **`RequestState`** in `api/src/states.js` and `worker/src/states.js`):

| State | Where it is written |
|-------|---------------------|
| `RECEIVED` | API after JWT validation, start of `POST /task` |
| `AUTHENTICATED` | API after recording successful JWT validation |
| `QUEUED` | API after successful publish to RabbitMQ |
| `CONSUMED` | Worker after valid HMAC, when a message is taken from the queue |
| `PROCESSED` | Worker after handling the task |
| `FAILED` | API if RabbitMQ publish fails; worker if HMAC invalid or processing throws |

Each transition row gets its own **`logged_at`** timestamp (`DEFAULT NOW()`).

### Database rules (assignment)

- **`request_id`**: UUID generated once per `/task` in the API; the same value is stored in every `audit_logs` / `request_states` row for that journey, embedded in the RabbitMQ message (`request_id` + `correlation_id`), and used again in the worker.
- **Timestamps**: each insert sets **`logged_at`** automatically (`DEFAULT NOW()`), so every audit line and every state transition has its own wall-clock time.
- **Renamed columns vs older runs**: if your Postgres volume was created before `action_performed` / `logged_at`, run `docker compose down -v` once (removes the volume) then `docker compose up --build -d` so `init.sql` applies cleanly.

## Deliverables checklist (course submission)

1. Source in this repository  
2. `docker-compose.yml` (+ `docker-compose.http-only.yml` for the lab)  
3. Schema: `db/init.sql`  
4. Screenshots (you capture locally): load-balanced **`handledBy`** values from `POST /task`, RabbitMQ queue depth / consumers, SQL query outputs, Wireshark HTTP vs HTTPS  
5. Short written summary: `REPORT.md`  
6. Publish to GitHub: `git init`, create a repo on GitHub, `git remote add origin ...`, `git push`

## Team workflow

Split ownership across Nginx/TLS, API + auth, worker + broker, database + observability queries, and Wireshark write-up so each member can explain the data path and security trade-offs end to end.
