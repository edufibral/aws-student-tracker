import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, UpdateCommand, DeleteCommand, ScanCommand } from "@aws-sdk/lib-dynamodb";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const tableName = process.env.TABLE_NAME;

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

const normalizeEmail = (value) => String(value || "").trim().toLowerCase();

const buildKey = (email) => {
  const normalized = normalizeEmail(email);
  if (!normalized) throw new Error("User email is required.");
  return { pk: `USER#${normalized}`, sk: "PROFILE", id: normalized };
};

export const handler = async (event) => {
  try {
    if (!tableName) return json(500, { error: "TABLE_NAME env var is required." });
    if (event.httpMethod === "OPTIONS") return json(200, { ok: true });

    if (event.httpMethod === "GET") {
      const result = await ddb.send(new ScanCommand({
        TableName: tableName,
        FilterExpression: "begins_with(pk, :prefix)",
        ExpressionAttributeValues: { ":prefix": "USER#" }
      }));

      return json(200, { items: result.Items || [] });
    }

    if (event.httpMethod === "POST") {
      const body = parseBody(event);
      if (!body.name || !body.email) {
        return json(400, { error: "name and email are required." });
      }

      const keys = buildKey(body.email);
      const now = new Date().toISOString();
      const item = {
        ...keys,
        entity: "user",
        email: keys.id,
        name: String(body.name).trim(),
        createdAt: now,
        updatedAt: now
      };

      await ddb.send(new PutCommand({
        TableName: tableName,
        Item: item,
        ConditionExpression: "attribute_not_exists(pk) AND attribute_not_exists(sk)"
      }));

      return json(201, { item });
    }

    if (event.httpMethod === "PUT") {
      const body = parseBody(event);
      const id = event.pathParameters?.id;
      const keys = buildKey(id);
      if (!body.name) return json(400, { error: "name is required for updates." });

      const result = await ddb.send(new UpdateCommand({
        TableName: tableName,
        Key: { pk: keys.pk, sk: keys.sk },
        ConditionExpression: "attribute_exists(pk)",
        UpdateExpression: "SET #name = :name, #updatedAt = :updatedAt",
        ExpressionAttributeNames: {
          "#name": "name",
          "#updatedAt": "updatedAt"
        },
        ExpressionAttributeValues: {
          ":name": String(body.name).trim(),
          ":updatedAt": new Date().toISOString()
        },
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
      return json(409, { error: "Duplicate or missing user record." });
    }
    return json(400, { error: error.message || "Unhandled error" });
  }
};
