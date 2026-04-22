/**
 * Mandatory request lifecycle states (assignment).
 * Must match db/init.sql CHECK on request_states.state exactly (spelling & case).
 */
export const RequestState = Object.freeze({
  RECEIVED: "RECEIVED",
  AUTHENTICATED: "AUTHENTICATED",
  QUEUED: "QUEUED",
  CONSUMED: "CONSUMED",
  PROCESSED: "PROCESSED",
  FAILED: "FAILED",
});
