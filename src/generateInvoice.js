import 'dotenv/config';
import { execFile } from "child_process";
import Handlebars from "handlebars";
import fs from "fs";
import path from "path";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

const s3 = new S3Client({ region: "ap-south-1" });

export async function generateInvoiceAndUpload(data) {
  const invoiceId = data.order_id;
  const year = new Date().getFullYear();
  const month = String(new Date().getMonth() + 1).padStart(2, "0");

  const s3Key = `invoices/${year}/${month}/${invoiceId}.pdf`;

  // Render HTML
  const templatePath = path.join(process.cwd(), "templates/invoice.html");
  const htmlTemplate = fs.readFileSync(templatePath, "utf8");
  const template = Handlebars.compile(htmlTemplate);
  const html = template(data);

  // Save HTML for debugging
  fs.writeFileSync(path.join(process.cwd(), "invoice.html"), html);

  console.log("Generated HTML:", html); // Debug log

  // Generate PDF using temp file
  const tempHtmlPath = path.join(process.cwd(), "temp_invoice.html");
  fs.writeFileSync(tempHtmlPath, html);

  const tempPdfPath = path.join(process.cwd(), "temp_invoice.pdf");

  await new Promise((resolve, reject) => {
    const wkhtmltopdfPath = process.platform === "win32" 
      ? "C:\\Program Files\\wkhtmltopdf\\bin\\wkhtmltopdf.exe" 
      : "wkhtmltopdf";
    const child = execFile(
      wkhtmltopdfPath,
      
      ["--quiet", tempHtmlPath, tempPdfPath],
      (error) => {
        if (error) return reject(error);
        resolve();
      }
    );
  });

  const pdfBuffer = fs.readFileSync(tempPdfPath);

  // Clean up temp files
  fs.unlinkSync(tempHtmlPath);
  fs.unlinkSync(tempPdfPath);

  // Upload directly to S3
  console.log("Uploading to S3...");
  const uploadResult = await s3.send(
    new PutObjectCommand({
      Bucket: process.env.INVOICE_BUCKET,
      Key: s3Key,
      Body: pdfBuffer,
      ContentType: "application/pdf",
      ServerSideEncryption: "AES256",
    })
  );
  

  // Return metadata for DB
  return {
    invoice_id: invoiceId,
    s3_key: s3Key,
  };
}