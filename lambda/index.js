import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";

const sqs = new SQSClient({ region: 'ap-south-1' });

export const handler = async (event) => {
  try {
    console.log("JSON.stringify(event)", JSON.stringify(event));

    //Parse incoming request body
    const body = JSON.parse(event.body || "{}");

    //Basic validation
    if (!body.invoiceNumber || !body.amount || !body.customerName || !body.email) {
      return {
        statusCode: 400,
        body: JSON.stringify({
          message: "Missing required fields: invoiceNumber, amount, customerName, email",
        }),
      };
    }

    //Prepare SQS message
    const message = {
      invoiceNumber: body.invoiceNumber,
      customerName: body.customerName,
      amount: body.amount,
      email: body.email || null,
      date: new Date().toISOString(),
    };

    //Push message to SQS
    await sqs.send(
      new SendMessageCommand({
        QueueUrl: process.env.SQS_QUEUE_URL,
        MessageBody: JSON.stringify(message),
        MessageGroupId: "invoice-group", // any logical grouping string fro fifo queue - ensures order within group
      })
    );

    //Return success response
    return {
      statusCode: 202,
      body: JSON.stringify({
        success: true,
        message: "Invoice request queued successfully",
      }),
    };
  } catch (error) {
    console.error("Lambda error:", error);

    return {
      statusCode: 500,
      body: JSON.stringify({
        success: false,
        message: "Internal server error",
      }),
    };
  }
};