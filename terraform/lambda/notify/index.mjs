import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const ses = new SESClient({});

const tableName = process.env.TABLE_NAME;
const fromEmail = process.env.SES_FROM_EMAIL;

const getUsers = async () => {
  const result = await ddb.send(new ScanCommand({
    TableName: tableName,
    FilterExpression: "begins_with(pk, :prefix)",
    ExpressionAttributeValues: { ":prefix": "USER#" }
  }));

  return (result.Items || []).map((item) => item.email).filter(Boolean);
};

const sendEmail = async ({ to, subject, body }) => {
  await ses.send(new SendEmailCommand({
    Source: fromEmail,
    Destination: { ToAddresses: [to] },
    Message: {
      Subject: { Data: subject, Charset: "UTF-8" },
      Body: { Text: { Data: body, Charset: "UTF-8" } }
    }
  }));
};

const parseRecordBody = (record) => {
  const body = JSON.parse(record.body || "{}");
  if (body.Type === "Notification" && body.Message) {
    return JSON.parse(body.Message);
  }
  return body;
};

export const handler = async (event) => {
  if (!tableName || !fromEmail) {
    throw new Error("TABLE_NAME and SES_FROM_EMAIL env vars are required.");
  }

  for (const record of event.Records || []) {
    const message = parseRecordBody(record);

    if (message.type === "course_created" || message.type === "program_created") {
      const recipients = await getUsers();
      const subject = message.subject || "Student Tracker update";
      const itemName = message.item?.name || message.item?.code || "a new item";

      await Promise.all(
        recipients.map((to) =>
          sendEmail({
            to,
            subject,
            body: `Student Tracker update: ${itemName} has been added.`
          })
        )
      );
    }

    if (message.type === "grade_created" && message.recipient) {
      await sendEmail({
        to: message.recipient,
        subject: message.subject || "New grade posted",
        body: message.body || "A new grade has been posted."
      });
    }
  }

  return {
    statusCode: 200,
    body: JSON.stringify({ processed: (event.Records || []).length })
  };
};
