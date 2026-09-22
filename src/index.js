import { S3Client, HeadObjectCommand, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";
import { SQSClient, ReceiveMessageCommand, DeleteMessageCommand } from "@aws-sdk/client-sqs";
import pg from "pg";
import { generateInvoiceAndUpload } from "./generateInvoice.js";

const { Pool } = pg;
const region = process.env.AWS_REGION || "ap-south-1";
const queueUrl = process.env.SQS_QUEUE_URL;
const bucket = process.env.INVOICE_BUCKET;
const sqs = new SQSClient({ region });
const s3 = new S3Client({ region });
const ses = new SESv2Client({ region });
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

let isShuttingDown = false;

process.on("SIGTERM", () => {
  console.log("Shutdown requested, finishing current work...");
  isShuttingDown = true;
});

async function ensureInvoiceTable(client) {
  await client.query(`
    CREATE TABLE IF NOT EXISTS invoice (
      order_id TEXT PRIMARY KEY,
      invoice_number TEXT NOT NULL,
      customer_name TEXT NOT NULL,
      amount NUMERIC NOT NULL,
      email TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('queued', 'processing', 'generated', 'mail_sent')),
      s3_key TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
  await client.query("ALTER TABLE invoice ADD COLUMN IF NOT EXISTS s3_key TEXT");
}

async function updateStatus(client, orderId, status, s3Key) {
  await client.query(
    `UPDATE invoice
     SET status = $2, s3_key = COALESCE($3, s3_key), updated_at = NOW()
     WHERE order_id = $1`,
    [orderId, status, s3Key || null]
  );
}

async function objectExists(key) {
  try {
    await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
    return true;
  } catch (error) {
    if (error.name === "NotFound" || error.$metadata?.httpStatusCode === 404) return false;
    throw error;
  }
}

async function sendInvoiceEmail(invoice, signedUrl) {
  await ses.send(new SendEmailCommand({
    FromEmailAddress: process.env.SES_FROM_EMAIL,
    Destination: { ToAddresses: [invoice.email] },
    Content: {
      Simple: {
        Subject: { Data: `Invoice ${invoice.invoice_number}` },
        Body: {
          Text: {
            Data: `Your invoice is ready. Download it here: ${signedUrl}\n\nThis link expires in ${process.env.INVOICE_URL_TTL_SECONDS || 3600} seconds.`,
          },
        },
      },
    },
  }));
}

async function processMessage(message) {
  const body = JSON.parse(message.Body);
  const orderId = body.order_id;
  if (!orderId) throw new Error("SQS message is missing order_id");

  const client = await pool.connect();
  try {
    await ensureInvoiceTable(client);
    const result = await client.query(
      "SELECT * FROM invoice WHERE order_id = $1 FOR UPDATE",
      [orderId]
    );
    if (result.rowCount === 0) throw new Error(`Invoice ${orderId} was not found in RDS`);

    const invoice = result.rows[0];
    if (invoice.status === "mail_sent") return;

    const existingKey = invoice.s3_key || `invoices/${new Date().getFullYear()}/${String(new Date().getMonth() + 1).padStart(2, "0")}/${orderId}.pdf`;
    if (await objectExists(existingKey)) {
      await updateStatus(client, orderId, "generated", existingKey);
    } else {
      await updateStatus(client, orderId, "processing");
      const generated = await generateInvoiceAndUpload(body);
      await updateStatus(client, orderId, "generated", generated.s3_key);
    }

    const stored = (await client.query("SELECT * FROM invoice WHERE order_id = $1", [orderId])).rows[0];
    const signedUrl = await getSignedUrl(
      s3,
      new GetObjectCommand({ Bucket: bucket, Key: stored.s3_key }),
      { expiresIn: Number(process.env.INVOICE_URL_TTL_SECONDS || 3600) }
    );
    await sendInvoiceEmail(stored, signedUrl);
    await updateStatus(client, orderId, "mail_sent");
  } finally {
    client.release();
  }
}

async function processMessages() {
  console.log("Starting SQS processor...");
  while (!isShuttingDown) {
    try {
      const response = await sqs.send(new ReceiveMessageCommand({
        QueueUrl: queueUrl,
        MaxNumberOfMessages: 10,
        WaitTimeSeconds: 20,
        VisibilityTimeout: 300,
      }));

      for (const message of response.Messages || []) {
        try {
          await processMessage(message);
          await sqs.send(new DeleteMessageCommand({
            QueueUrl: queueUrl,
            ReceiptHandle: message.ReceiptHandle,
          }));
          console.log(`Processed: ${message.MessageId}`);
        } catch (error) {
          console.error("Error processing message:", error);
        }
      }
    } catch (error) {
      console.error("Polling error:", error);
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }
  }
  await pool.end();
}

processMessages().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
