-- Audit logging: one row per action (assignment: timestamp, service_name, request_id,
-- action_performed, status, source). logged_at is the wall-clock timestamp for the row.
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

COMMENT ON COLUMN audit_logs.logged_at IS 'Timestamp when this audit row was recorded.';
COMMENT ON COLUMN audit_logs.request_id IS 'Same UUID as the request across API, broker, and worker.';

CREATE INDEX IF NOT EXISTS idx_audit_logs_request_id ON audit_logs (request_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_logged_at ON audit_logs (logged_at);

-- One row per state transition. Allowed state values (mandatory, exact spelling):
-- RECEIVED, AUTHENTICATED, QUEUED, CONSUMED, PROCESSED, FAILED
-- Keep in sync with api/src/states.js and worker/src/states.js
CREATE TABLE IF NOT EXISTS request_states (
    id              BIGSERIAL PRIMARY KEY,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    request_id      UUID NOT NULL,
    state           VARCHAR(32) NOT NULL CHECK (
        state IN (
            'RECEIVED',
            'AUTHENTICATED',
            'QUEUED',
            'CONSUMED',
            'PROCESSED',
            'FAILED'
        )
    ),
    service_name    VARCHAR(64) NOT NULL,
    metadata        JSONB
);

COMMENT ON COLUMN request_states.logged_at IS 'Timestamp when this state transition was recorded.';
COMMENT ON COLUMN request_states.request_id IS 'Unique request UUID; identical value in API, messages, and worker.';

CREATE INDEX IF NOT EXISTS idx_request_states_request_id ON request_states (request_id);
CREATE INDEX IF NOT EXISTS idx_request_states_logged_at ON request_states (logged_at);
