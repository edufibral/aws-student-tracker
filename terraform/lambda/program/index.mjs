import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, UpdateCommand, DeleteCommand, ScanCommand } from "@aws-sdk/lib-dynamodb";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const sns = new SNSClient({});

const tableName = process.env.TABLE_NAME;
const topicArn = process.env.MAJOR_EVENTS_TOPIC_ARN;

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

const normalizeCode = (value) => String(value || "").trim().toUpperCase();

const buildKey = (code) => {
  const normalized = normalizeCode(code);
  if (!normalized) throw new Error("Program code is required.");
  return { pk: `PROGRAM#${normalized}`, sk: "PROGRAM", id: normalized };
};

export const handler = async (event) => {
  try {
    if (!tableName) return json(500, { error: "TABLE_NAME env var is required." });
    if (event.httpMethod === "OPTIONS") return json(200, { ok: true });

    if (event.httpMethod === "GET") {
      const result = await ddb.send(new ScanCommand({
        TableName: tableName,
        FilterExpression: "begins_with(pk, :prefix)",
        ExpressionAttributeValues: { ":prefix": "PROGRAM#" }
      }));

      return json(200, { items: result.Items || [] });
    }

    if (event.httpMethod === "POST") {
      const body = parseBody(event);
      if (!body.code || !body.name) return json(400, { error: "code and name are required." });

      const keys = buildKey(body.code);
      const now = new Date().toISOString();
      const item = {
        ...keys,
        entity: "program",
        code: keys.id,
        name: String(body.name).trim(),
        degreeType: body.degreeType ? String(body.degreeType).trim() : null,
        createdAt: now,
        updatedAt: now
      };

      await ddb.send(new PutCommand({
        TableName: tableName,
        Item: item,
        ConditionExpression: "attribute_not_exists(pk) AND attribute_not_exists(sk)"
      }));

      if (topicArn) {
        await sns.send(new PublishCommand({
          TopicArn: topicArn,
          Message: JSON.stringify({ type: "program_created", item, subject: `New program created: ${item.code}` })
        }));
      }

      return json(201, { item });
    }

    if (event.httpMethod === "PUT") {
      const body = parseBody(event);
      const id = event.pathParameters?.id;
      const keys = buildKey(id);
      if (!body.name && !body.degreeType) {
        return json(400, { error: "Provide name and/or degreeType to update." });
      }

      const updates = ["#updatedAt = :updatedAt"];
      const names = { "#updatedAt": "updatedAt" };
      const values = { ":updatedAt": new Date().toISOString() };

      if (body.name) {
        names["#name"] = "name";
        values[":name"] = String(body.name).trim();
        updates.push("#name = :name");
      }

      if (body.degreeType) {
        names["#degreeType"] = "degreeType";
        values[":degreeType"] = String(body.degreeType).trim();
        updates.push("#degreeType = :degreeType");
      }

      const result = await ddb.send(new UpdateCommand({
        TableName: tableName,
        Key: { pk: keys.pk, sk: keys.sk },
        ConditionExpression: "attribute_exists(pk)",
        UpdateExpression: `SET ${updates.join(", ")}`,
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: values,
        ReturnValues: "ALL_NEW"
      }));

      return json(200, { item: result.Attributes });
    }

    if (event.httpMethod === "DELETE") {
      const id = event.pathParameters?.id;
      const keys = buildKey(id);

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
      return json(409, { error: "Duplicate or missing program record." });
    }
    return json(400, { error: error.message || "Unhandled error" });
  }
};
