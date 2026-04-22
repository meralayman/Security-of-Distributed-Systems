/** Same semantics as api/src/rabbitmq-setup.js (duplicate for Docker image isolation). */
const DLX_EXCHANGE = process.env.TASK_DLX_EXCHANGE || "tasks_dlx";
const DLX_ROUTE = process.env.TASK_DLX_ROUTE || "dead";
const DEAD_QUEUE = process.env.TASK_DEAD_QUEUE || "tasks_dead";

export function isDlxEnabled() {
  return String(process.env.ENABLE_TASK_DLX || "").toLowerCase() === "true";
}

export async function assertTaskTopology(ch, taskQueueName) {
  if (isDlxEnabled()) {
    await ch.assertExchange(DLX_EXCHANGE, "direct", { durable: true });
    await ch.assertQueue(DEAD_QUEUE, { durable: true });
    await ch.bindQueue(DEAD_QUEUE, DLX_EXCHANGE, DLX_ROUTE);
    await ch.assertQueue(taskQueueName, {
      durable: true,
      arguments: {
        "x-dead-letter-exchange": DLX_EXCHANGE,
        "x-dead-letter-routing-key": DLX_ROUTE,
      },
    });
  } else {
    await ch.assertQueue(taskQueueName, { durable: true });
  }
}
