import amqp from "amqplib";

import pg from "pg";

import { verifySig } from "./sign.js";

import { RequestState } from "./states.js";

import { assertTaskTopology } from "./rabbitmq-setup.js";



const SERVICE_NAME = process.env.SERVICE_NAME || "worker";

const DATABASE_URL = process.env.DATABASE_URL;

const RABBITMQ_URL = process.env.RABBITMQ_URL;

const INTERNAL_SERVICE_TOKEN = process.env.INTERNAL_SERVICE_TOKEN;

const TASK_QUEUE = process.env.TASK_QUEUE || "tasks_queue";



const WORKER_MAX_RETRIES = Math.max(1, Number(process.env.WORKER_MAX_RETRIES || 3));

const WORKER_RETRY_DELAY_MS = Math.max(0, Number(process.env.WORKER_RETRY_DELAY_MS || 150));



const pool = new pg.Pool({ connectionString: DATABASE_URL });



function sleep(ms) {

  return new Promise((r) => setTimeout(r, ms));

}

/** RabbitMQ may report healthy before AMQP accepts connections — retry startup (ECONNREFUSED). */
async function connectAmqpWithBackoff() {
  const max = Math.max(1, Number(process.env.RABBIT_CONNECT_RETRIES || 60));
  const delayMs = Math.max(250, Number(process.env.RABBIT_CONNECT_DELAY_MS || 2000));
  let lastErr;
  for (let i = 0; i < max; i++) {
    try {
      return await amqp.connect(RABBITMQ_URL);
    } catch (err) {
      lastErr = err;
      console.error(`[worker] RabbitMQ connect attempt ${i + 1}/${max}: ${err.code || err.message}`);
      await sleep(delayMs);
    }
  }
  throw lastErr;
}



async function insertState(client, { requestId, state, serviceName, metadata }) {

  await client.query(

    `INSERT INTO request_states (request_id, state, service_name, metadata)

     VALUES ($1::uuid, $2, $3, $4::jsonb)`,

    [requestId, state, serviceName, metadata ? JSON.stringify(metadata) : null]

  );

}



async function insertAudit(client, { serviceName, requestId, actionPerformed, status, source, detail }) {

  await client.query(

    `INSERT INTO audit_logs (logged_at, service_name, request_id, action_performed, status, source, detail)

     VALUES (NOW(), $1, $2::uuid, $3, $4, $5, $6::jsonb)`,

    [serviceName, requestId, actionPerformed, status, source, detail ? JSON.stringify(detail) : null]

  );

}



async function persistProcessed(client, requestId, payload, attemptsUsed) {

  await new Promise((r) => setTimeout(r, 50));

  const result = {

    echo: payload,

    handled_by: SERVICE_NAME,

    ...(attemptsUsed > 1 ? { worker_retries: attemptsUsed - 1 } : {}),

  };

  await client.query("BEGIN");

  try {

    await insertState(client, {

      requestId,

      state: RequestState.PROCESSED,

      serviceName: SERVICE_NAME,

      metadata: { result_keys: Object.keys(result), attempts: attemptsUsed },

    });

    await insertAudit(client, {

      serviceName: SERVICE_NAME,

      requestId,

      actionPerformed: "Task processed",

      status: "success",

      source: "service",

      detail: { result },

    });

    await client.query("COMMIT");

  } catch (e) {

    await client.query("ROLLBACK").catch(() => {});

    throw e;

  }

}



async function processMessage(buf) {

  let requestId = null;

  let data;

  try {

    data = JSON.parse(buf.toString("utf8"));

  } catch (e) {

    throw e;

  }



  requestId = data.request_id;

  const payload = data.payload;

  const producer = data.service;

  const proof = data.internal_token ?? data.sig ?? "";



  const client = await pool.connect();

  try {

    if (!verifySig(requestId, payload, producer, proof, INTERNAL_SERVICE_TOKEN)) {

      await client.query("BEGIN");

      await insertState(client, {

        requestId,

        state: RequestState.FAILED,

        serviceName: SERVICE_NAME,

        metadata: { reason: "invalid_internal_token", claimed_producer: producer },

      });

      await insertAudit(client, {

        serviceName: SERVICE_NAME,

        requestId,

        actionPerformed: "Rejected task: invalid internal token (service identity)",

        status: "failure",

        source: "service",

        detail: { claimed_producer: producer },

      });

      await client.query("COMMIT");

      return;

    }



    await client.query("BEGIN");

    await insertState(client, {

      requestId,

      state: RequestState.CONSUMED,

      serviceName: SERVICE_NAME,

      metadata: { producer },

    });

    await insertAudit(client, {

      serviceName: SERVICE_NAME,

      requestId,

      actionPerformed: "Task consumed from RabbitMQ",

      status: "success",

      source: "service",

      detail: { producer },

    });

    await client.query("COMMIT");



    let lastErr = null;

    for (let attempt = 1; attempt <= WORKER_MAX_RETRIES; attempt++) {

      try {

        await persistProcessed(client, requestId, payload, attempt);

        return;

      } catch (err) {

        lastErr = err;

        if (attempt < WORKER_MAX_RETRIES) {

          await sleep(WORKER_RETRY_DELAY_MS * attempt);

        }

      }

    }



    await client.query("BEGIN");

    await insertState(client, {

      requestId,

      state: RequestState.FAILED,

      serviceName: SERVICE_NAME,

      metadata: { error: String(lastErr), retries: WORKER_MAX_RETRIES },

    });

    await insertAudit(client, {

      serviceName: SERVICE_NAME,

      requestId,

      actionPerformed: "Task processing failed after retries",

      status: "failure",

      source: "service",

      detail: { error: String(lastErr), retries: WORKER_MAX_RETRIES },

    });

    await client.query("COMMIT");

    throw lastErr;

  } finally {

    client.release();

  }

}



async function main() {

  if (!INTERNAL_SERVICE_TOKEN) {

    console.error("INTERNAL_SERVICE_TOKEN is required for service-to-service verification");

    process.exit(1);

  }

  const conn = await connectAmqpWithBackoff();

  const ch = await conn.createChannel();

  await assertTaskTopology(ch, TASK_QUEUE);

  await ch.prefetch(1);

  await ch.consume(TASK_QUEUE, async (msg) => {

    if (!msg) return;

    try {

      await processMessage(msg.content);

      ch.ack(msg);

    } catch (e) {

      if (e instanceof SyntaxError) {

        ch.nack(msg, false, false);

      } else {

        ch.nack(msg, false, false);

      }

    }

  });

  // eslint-disable-next-line no-console

  console.log(`${SERVICE_NAME} consuming queue ${TASK_QUEUE} (retries=${WORKER_MAX_RETRIES}, dlx=${process.env.ENABLE_TASK_DLX || "false"})`);

}



main().catch((e) => {

  console.error(e);

  process.exit(1);

});


