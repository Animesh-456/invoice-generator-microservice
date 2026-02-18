// import { generateInvoiceAndUpload } from "./generateInvoice.js";
// import {
//   SQSClient,
//   ReceiveMessageCommand,
//   DeleteMessageCommand,
// } from "@aws-sdk/client-sqs";

// const sqs = new SQSClient({ region: "ap-south-1" });
// const queueUrl = process.env.SQS_QUEUE_URL;

// const MAX_EMPTY_POLLS = 3; // exit after 3 empty polls
// let emptyPolls = 0;

// async function processMessages() {
//   while (true) {
//     try {
//       const response = await sqs.send(
//         new ReceiveMessageCommand({
//           QueueUrl: queueUrl,
//           MaxNumberOfMessages: 5, // better than 1
//           WaitTimeSeconds: 20,
//         })
//       );

//       if (!response.Messages || response.Messages.length === 0) {
//         emptyPolls++;
//         console.log(`No messages. Empty poll #${emptyPolls}`);

//         if (emptyPolls >= MAX_EMPTY_POLLS) {
//           console.log("No more messages. Exiting ECS.");
//           break;
//         }

//         continue;
//       }


//       // Reset counter when message is found
//       emptyPolls = 0;


//       if (response.Messages && response.Messages.length > 0) {
        
//         for (const message of response.Messages) {
//           const body = JSON.parse(message.Body);

//           await generateInvoiceAndUpload(body);


//           // ###########################################
//           // Store invoice metadata in RDS
//           // ###########################################

//           await sqs.send(
//             new DeleteMessageCommand({
//               QueueUrl: queueUrl,
//               ReceiptHandle: message.ReceiptHandle,
//             })
//           );
//         }
//       }

//     } catch (err) {
//       console.error("Error:", err);
//     }
//   }

//   //process.exit(0); // VERY IMPORTANT
// }

// processMessages();


import { generateInvoiceAndUpload } from "./generateInvoice.js";
import {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} from "@aws-sdk/client-sqs";

const sqs = new SQSClient({ region: "ap-south-1" });
const queueUrl = process.env.SQS_QUEUE_URL;

let isShuttingDown = false;

// Handle ECS shutdown signals (for deployments, etc.)
process.on("SIGTERM", () => {
  console.log("Shutdown requested, finishing current work...");
  isShuttingDown = true;
});

async function processMessages() {
  console.log("Starting SQS processor...");
  
  // Infinite loop - runs forever until SIGTERM
  while (!isShuttingDown) {
    try {
      const response = await sqs.send(
        new ReceiveMessageCommand({
          QueueUrl: queueUrl,
          MaxNumberOfMessages: 10,
          WaitTimeSeconds: 20,
        })
      );

      // No messages? Do nothing, just continue polling
      if (!response.Messages || response.Messages.length === 0) {
        console.log("No messages, continuing to poll...");
        continue;  // ← Just waits and tries again
      }

      console.log(`Processing ${response.Messages.length} messages`);

      for (const message of response.Messages) {
        try {
          const body = JSON.parse(message.Body);
          await generateInvoiceAndUpload(body);
          
          await sqs.send(
            new DeleteMessageCommand({
              QueueUrl: queueUrl,
              ReceiptHandle: message.ReceiptHandle,
            })
          );
          
          console.log(`Processed: ${message.MessageId}`);
        } catch (err) {
          console.error(`Error processing message:`, err);
        }
      }
    } catch (err) {
      console.error("Polling error:", err);
      await new Promise(resolve => setTimeout(resolve, 5000));
    }
  }

  console.log("Graceful shutdown complete");
  process.exit(0);
}

processMessages().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});