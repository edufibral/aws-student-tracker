const AWS = require("aws-sdk");

const ddb = new AWS.DynamoDB.DocumentClient();
const ses = new AWS.SES();

const TABLE_NAME = process.env.TABLE_NAME;
const SES_FROM_EMAIL = process.env.SES_FROM_EMAIL;

async function listAllUserEmails() {
  const result = await ddb
    .scan({
      TableName: TABLE_NAME,
      FilterExpression: "begins_with(pk, :prefix)",
      ExpressionAttributeValues: {
        ":prefix": "USER#"
      }
    })
    .promise();

  return (result.Items || [])
    .map((item) => item.email)
    .filter((email) => !!email);
}

async function sendEmail(to, subject, bodyText) {
  if (!to) return;
  await ses
    .sendEmail({
      Source: SES_FROM_EMAIL,
      Destination: {
        ToAddresses: [to]
      },
      Message: {
        Subject: {
          Data: subject,
          Charset: "UTF-8"
        },
        Body: {
          Text: {
            Data: bodyText,
            Charset: "UTF-8"
          }
        }
      }
    })
    .promise();
}

function parseQueueRecord(record) {
  const body = JSON.parse(record.body || "{}");

  if (body.Type === "Notification" && body.Message) {
    return JSON.parse(body.Message);
  }

  return body;
}

exports.handler = async (event) => {
  const records = event.Records || [];

  for (const record of records) {
    const message = parseQueueRecord(record);

    if (message.type === "course_created" || message.type === "program_created") {
      const emails = await listAllUserEmails();
      const subject = message.subject || "New update available";
      const itemName = message.item && (message.item.name || message.item.code) ? `${message.item.name || message.item.code}` : "a new item";
      const bodyText = `Student Tracker update: ${itemName} was added.`;

      for (const email of emails) {
        await sendEmail(email, subject, bodyText);
      }
    }

    if (message.type === "grade_created") {
      await sendEmail(message.recipient, message.subject || "New grade posted", message.body || "A new grade has been posted.");
    }
  }

  return {
    statusCode: 200,
    body: JSON.stringify({ processed: records.length })
  };
};
