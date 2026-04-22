import crypto from "crypto";

/** Match Python json.dumps(..., sort_keys=True, separators=(',', ':')) for objects/arrays/primitives */
export function stableStringify(val) {
  if (val === null || typeof val !== "object") {
    return JSON.stringify(val);
  }
  if (Array.isArray(val)) {
    return `[${val.map(stableStringify).join(",")}]`;
  }
  const keys = Object.keys(val).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${stableStringify(val[k])}`).join(",")}}`;
}

export function signPayload(requestId, payload, serviceName, secret) {
  const canonical = `${requestId}|${stableStringify(payload)}|${serviceName}`;
  return crypto.createHmac("sha256", secret).update(canonical, "utf8").digest("hex");
}
