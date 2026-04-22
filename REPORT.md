# Short Report: Secure Distributed System with Observability

## 1. Architecture

The client talks only to **Nginx**, which terminates **TLS**, enforces **per-IP rate limits**, and load-balances across **three stateless API replicas**. Each API instance authenticates callers with **JWT**, assigns a single **UUID request identifier** for the lifecycle of that operation, persists **audit log entries** and **state transitions** in **PostgreSQL**, and publishes a **signed** task envelope to **RabbitMQ**. A single **worker** process consumes the queue, **recomputes the HMAC** to confirm the message originated from a trusted API instance using the shared `INTERNAL_SERVICE_TOKEN`, performs lightweight processing, and records further audit/state rows using the **same request ID**.

This layout matches the assignment control flow: gateway security and traffic shaping at the edge, authentication and correlation identifiers at the service tier, asynchronous hand-off through a broker, and durable observability in a database suitable for incident review.

## 2. Security mechanisms

- **Transport security (HTTPS)**: TLS 1.2+ between browser or `curl` and Nginx; cleartext is confined to the internal Docker network by default.
- **Authentication**: APIs require `Authorization: Bearer` JWTs signed with `JWT_SECRET`. Requests without valid tokens never receive a server-generated `request_id` in the happy path described in the brief (the demo issues tokens via `/auth/token` for lab convenience only).
- **Inter-service integrity**: RabbitMQ messages carry `request_id`, `payload`, `service`, and **`internal_token`** (HMAC-SHA256 proof derived from shared **`INTERNAL_SERVICE_TOKEN`**). The worker rejects tampered or forged messages before marking work as consumed.
- **Rate limiting**: Nginx `limit_req` reduces abusive traffic before it reaches application processes.

## 3. Observability: audit logging and state tracking

`audit_logs` captures **who did what, when, for which request, from which origin class (client vs service), and whether it succeeded**. `request_states` stores every transition across the enumerated lifecycle (`RECEIVED`, `AUTHENTICATED`, `QUEUED`, `CONSUMED`, `PROCESSED`, `FAILED`) with timestamps, enabling reconstructions of slow or failed pipelines for a given `request_id`.

## 4. HTTP vs HTTPS (Wireshark discussion)

With the **HTTP-only** compose profile, Wireshark shows **readable HTTP** segments: method and path, **Authorization** headers, JSON bodies, and RabbitMQ remains internal but the browser/API leg is fully visible—this illustrates why unencrypted HTTP on untrusted networks exposes bearer tokens and payloads to passive observers.

With the **default HTTPS** stack, the same capture shows **TLS Application Data** records without recoverable HTTP semantics unless keys are imported into Wireshark (not done here). Practically, **JWTs and JSON bodies are no longer visible on the wire** between the client and Nginx, satisfying the assignment’s contrast requirement.

## 5. Testing performed

- Valid `/task` flow returns `requestId` and `handledBy`, with matching `X-API-Instance` header.  
- Repeated calls demonstrate **round-robin load balancing** across `api1`–`api3`.  
- Missing/invalid JWT yields **401**.  
- Sustained `/health` calls trigger **429** once the configured rate is exceeded.  
- RabbitMQ shows the **`tasks_queue`** queue draining while the worker runs.  
- SQL queries against `audit_logs` and `request_states` confirm **cross-service correlation** on one `request_id`.

## 6. Design trade-offs

A shared **symmetric** HMAC secret is adequate for a closed lab network; production systems would rotate keys via a secret manager, scope credentials per service identity, and likely adopt **mTLS** or **token-based broker auth** in addition to payload signing. JWT issuance is simplified to a static demo credential pair; a real deployment would integrate with an identity provider and short-lived tokens with refresh handling.
