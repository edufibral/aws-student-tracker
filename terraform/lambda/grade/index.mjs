import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, UpdateCommand, DeleteCommand, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const sqs = new SQSClient({});

const tableName = process.env.TABLE_NAME;
const queueUrl = process.env.NOTIFICATIONS_QUEUE_URL;

const json = (statusCode, body) => ({
  statusCode,
  headers: {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS"
  },
  body: JSON.stringify(body)
});

const parseBody = (event) => {
  if (!event.body) return {};
  try {
    return JSON.parse(event.body);
  } catch {
    throw new Error("Request body must be valid JSON.");
  }
};

const buildKey = ({ studentId, courseCode, id }) => {
  const sid = String(studentId || "").trim();
  const ccode = String(courseCode || "").trim().toUpperCase();
  if (sid && ccode) {
    return { pk: `GRADE#${sid}#${ccode}`, sk: "GRADE", id: `${sid}:${ccode}` };
  }

  const raw = String(id || "").trim();
  const [idStudent, idCourse] = raw.split(":");
  if (!idStudent || !idCourse) throw new Error("Grade id must be in format studentId:courseCode.");

  const normalizedCourse = idCourse.trim().toUpperCase();
  return { pk: `GRADE#${idStudent.trim()}#${normalizedCourse}`, sk: "GRADE", id: `${idStudent.trim()}:${normalizedCourse}` };
};

export const handler = async (event) => {
  try {
    if (!tableName) return json(500, { error: "TABLE_NAME env var is required." });
    if (event.httpMethod === "OPTIONS") return json(200, { ok: true });

    if (event.httpMethod === "GET") {
      const result = await ddb.send(new ScanCommand({
        TableName: tableName,
        FilterExpression: "begins_with(pk, :prefix)",
        ExpressionAttributeValues: { ":prefix": "GRADE#" }
      }));

      return json(200, { items: result.Items || [] });
    }

    if (event.httpMethod === "POST") {
      const body = parseBody(event);
      if (!body.studentId || !body.courseCode || !body.grade || !body.userEmail) {
        return json(400, { error: "studentId, courseCode, grade, and userEmail are required." });
      }

      const keys = buildKey(body);
      const now = new Date().toISOString();
      const item = {
        ...keys,
        entity: "grade",
        studentId: String(body.studentId).trim(),
        courseCode: String(body.courseCode).trim().toUpperCase(),
        grade: String(body.grade).trim(),
        userEmail: String(body.userEmail).trim().toLowerCase(),
        createdAt: now,
        updatedAt: now
      };

      await ddb.send(new PutCommand({
        TableName: tableName,
        Item: item,
        ConditionExpression: "attribute_not_exists(pk) AND attribute_not_exists(sk)"
      }));

      if (queueUrl) {
        await sqs.send(new SendMessageCommand({
          QueueUrl: queueUrl,
          MessageBody: JSON.stringify({
            type: "grade_created",
            recipient: item.userEmail,
            subject: `New grade posted for ${item.courseCode}`,
            body: `A new grade (${item.grade}) was posted for ${item.courseCode}.`
          })
        }));
      }

      return json(201, { item });
    }

    if (event.httpMethod === "PUT") {
      const body = parseBody(event);
      const id = event.pathParameters?.id;
      const keys = buildKey({ id });
      if (!body.grade) return json(400, { error: "grade is required for updates." });

      const result = await ddb.send(new UpdateCommand({
        TableName: tableName,
        Key: { pk: keys.pk, sk: keys.sk },
        ConditionExpression: "attribute_exists(pk)",
        UpdateExpression: "SET #grade = :grade, #updatedAt = :updatedAt",
        ExpressionAttributeNames: {
          "#grade": "grade",
          "#updatedAt": "updatedAt"
        },
        ExpressionAttributeValues: {
          ":grade": String(body.grade).trim(),
          ":updatedAt": new Date().toISOString()
        },
        ReturnValues: "ALL_NEW"
      }));

      return json(200, { item: result.Attributes });
    }

    if (event.httpMethod === "DELETE") {
      const id = event.pathParameters?.id;
      const keys = buildKey({ id });

      await ddb.send(new DeleteCommand({
        TableName: tableName,
        Key: { pk: keys.pk, sk: keys.sk },
        ConditionExpression: "attribute_exists(pk)"
      }));

      return json(200, { deleted: keys.id });
    }

    return json(405, { error: "Method not allowed." });
  } catch (error) {
    if (error.name === "ConditionalCheckFailedException") {
      return json(409, { error: "Duplicate or missing grade record." });
    }
    return json(400, { error: error.message || "Unhandled error" });
  }
};
