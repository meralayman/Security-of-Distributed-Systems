import amqp from "amqplib";
import { signPayload } from "./sign.js";
import { assertTaskTopology } from "./rabbitmq-setup.js";

export async function publishTask({ requestId, payload, serviceName }) {
  const secret = process.env.INTERNAL_SERVICE_TOKEN;
  if (!secret) throw new Error("INTERNAL_SERVICE_TOKEN is not set");

  const rid = String(requestId);
  /** HMAC-SHA256 proof of INTERNAL_SERVICE_TOKEN (never send the secret on the wire). */
  const internal_token = signPayload(rid, payload, serviceName, secret);
  const body = {
    request_id: rid,
    payload,
    service: serviceName,
    internal_token,
    sig: internal_token,
  };
  const raw = JSON.stringify(body);

  const url = process.env.RABBITMQ_URL;
  const queue = process.env.TASK_QUEUE || "tasks_queue";

  const conn = await amqp.connect(url);
  try {
    const ch = await conn.createChannel();
    await assertTaskTopology(ch, queue);
    ch.sendToQueue(queue, Buffer.from(raw, "utf8"), {
      persistent: true,
      contentType: "application/json",
      correlationId: rid,
    });
    await ch.close();
  } finally {
    await conn.close();
  }
}
