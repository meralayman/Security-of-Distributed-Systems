import crypto from "crypto";

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

export function verifySig(requestId, payload, service, sig, secret) {
  const expected = signPayload(requestId, payload, service, secret);
  try {
    return crypto.timingSafeEqual(Buffer.from(expected, "hex"), Buffer.from(sig, "hex"));
  } catch {
    return false;
  }
}
