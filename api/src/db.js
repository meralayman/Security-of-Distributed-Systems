import pg from "pg";

export const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
});

// ---------------- STATES ----------------

export async function insertState(client, { requestId, state, serviceName, metadata }) {
  await client.query(
    `INSERT INTO request_states (request_id, state, service_name, metadata)
     VALUES ($1::uuid, $2, $3, $4::jsonb)`,
    [requestId, state, serviceName, metadata ? JSON.stringify(metadata) : null]
  );
}

export async function fetchStatesForRequest(requestId) {
  const r = await pool.query(
    `SELECT state, service_name, created_at, metadata
     FROM request_states 
     WHERE request_id = $1::uuid 
     ORDER BY created_at ASC`,
    [requestId]
  );
  return r.rows;
}

export async function fetchRecentStateRows(limit = 40) {
  const r = await pool.query(
    `SELECT created_at, request_id, state, service_name
     FROM request_states 
     ORDER BY created_at DESC 
     LIMIT $1`,
    [limit]
  );
  return r.rows;
}

// ---------------- AUDIT ----------------

export async function insertAudit(client, { serviceName, requestId, actionPerformed, status, source, detail }) {
  await client.query(
    `INSERT INTO audit_logs (service_name, request_id, action, status, source, detail)
     VALUES ($1, $2::uuid, $3, $4, $5, $6::jsonb)`,
    [serviceName, requestId, actionPerformed, status, source, detail ? JSON.stringify(detail) : null]
  );
}

export async function fetchAuditsForRequest(requestId) {
  const r = await pool.query(
    `SELECT created_at, service_name, action, status, source, detail
     FROM audit_logs 
     WHERE request_id = $1::uuid 
     ORDER BY created_at ASC`,
    [requestId]
  );
  return r.rows;
}

export async function fetchRecentAuditRows(limit = 40) {
  const r = await pool.query(
    `SELECT created_at, service_name, request_id, action, status, source
     FROM audit_logs 
     ORDER BY created_at DESC 
     LIMIT $1`,
    [limit]
  );
  return r.rows;
}