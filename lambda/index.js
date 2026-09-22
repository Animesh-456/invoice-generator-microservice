import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import pg from "pg";

const { Pool } = pg;
const sqs = new SQSClient({ region: process.env.AWS_REGION || "ap-south-1" });
const pool = new Pool({
  host: process.env.RDS_PROXY_ENDPOINT,
  port: Number(process.env.DB_PORT || 5432),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  ssl: process.env.DB_SSL === "false" ? false : { rejectUnauthorized: false },
  max: 2,
  idleTimeoutMillis: 5000,
  connectionTimeoutMillis: 5000,
});

const createInvoiceTable = async (client) => {
  await client.query(`
    CREATE TABLE IF NOT EXISTS invoice (
      order_id TEXT PRIMARY KEY,
      invoice_number TEXT NOT NULL,
      customer_name TEXT NOT NULL,
      amount NUMERIC NOT NULL,
      email TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('queued', 'processing', 'generated', 'mail_sent')),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
};

const enqueue = (message) => sqs.send(new SendMessageCommand({
  QueueUrl: process.env.SQS_QUEUE_URL,
  MessageBody: JSON.stringify(message),
  MessageGroupId: "invoice-group",
  MessageDeduplicationId: message.order_id,
}));

export const handler = async (event) => {
  let client;
  try {
    console.log("JSON.stringify(event)", JSON.stringify(event));
    const body = JSON.parse(event.body || "{}");

    if (!body.orderId || !body.invoiceNumber || body.amount == null || !body.customerName || !body.email) {
      return {
        statusCode: 400,
        body: JSON.stringify({
          message: "Missing required query parameter: order_id or required fields: invoiceNumber, amount, customerName, email",
        }),
      };
    }

    const message = {
      order_id: body.orderId,
      invoiceNumber: body.invoiceNumber,
      customerName: body.customerName,
      amount: body.amount,
      email: body.email,
      date: new Date().toISOString(),
    };

    client = await pool.connect();
    await createInvoiceTable(client);
    const existing = await client.query(
      "SELECT status FROM invoice WHERE order_id = $1",
      [body.orderId]
    );

    if (existing.rowCount > 0) {
      const status = existing.rows[0].status;
      if (status === "mail_sent" || status === "generated") {
        return {
          statusCode: 200,
          body: JSON.stringify({ success: true, order_id: body.orderId, status }),
        };
      }

      await enqueue(message);
      return {
        statusCode: 202,
        body: JSON.stringify({ success: true, order_id: body.orderId, status }),
      };
    }

    await client.query(
      `INSERT INTO invoice
        (order_id, invoice_number, customer_name, amount, email, status)
       VALUES ($1, $2, $3, $4, $5, 'queued')`,
      [body.orderId, body.invoiceNumber, body.customerName, body.amount, body.email]
    );
    await enqueue(message);

    return {
      statusCode: 202,
      body: JSON.stringify({
        success: true,
        order_id: body.orderId,
        message: "Invoice request queued successfully",
      }),
    };
  } catch (error) {
    console.error("Lambda error:", error);
    return {
      statusCode: 500,
      body: JSON.stringify({ success: false, message: "Internal server error" }),
    };
  } finally {
    client?.release();
  }
};
