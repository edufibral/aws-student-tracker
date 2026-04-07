const AWS = require("aws-sdk");

const ddb = new AWS.DynamoDB.DocumentClient();
const sns = new AWS.SNS();
const sqs = new AWS.SQS();

const TABLE_NAME = process.env.TABLE_NAME;
const ENTITY = process.env.ENTITY;
const OPERATION = process.env.OPERATION;
const SNS_TOPIC_ARN = process.env.SNS_TOPIC_ARN;
const NOTIFICATIONS_QUEUE_URL = process.env.NOTIFICATIONS_QUEUE_URL;

const REQUIRED_FIELDS = {
  users: ["email", "name"],
  programs: ["code", "name"],
  courses: ["code", "name", "credits"],
  grades: ["studentId", "courseCode", "grade", "userEmail"]
};

function response(statusCode, body) {
  return {
    statusCode,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Content-Type,Authorization",
      "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS"
    },
    body: JSON.stringify(body)
  };
}

function parseBody(event) {
  if (!event.body) return {};
  try {
    return JSON.parse(event.body);
  } catch (err) {
    throw new Error("Invalid JSON body");
  }
}

function buildKeys(entity, valueSource) {
  if (entity === "users") {
    const email = String(valueSource.email || valueSource.id || "").toLowerCase().trim();
    if (!email) throw new Error("Missing user email");
    return { pk: `USER#${email}`, sk: "PROFILE", uniqueId: email };
  }

  if (entity === "programs") {
    const code = String(valueSource.code || valueSource.id || "").toUpperCase().trim();
    if (!code) throw new Error("Missing program code");
    return { pk: `PROGRAM#${code}`, sk: "PROGRAM", uniqueId: code };
  }

  if (entity === "courses") {
    const code = String(valueSource.code || valueSource.id || "").toUpperCase().trim();
    if (!code) throw new Error("Missing course code");
    return { pk: `COURSE#${code}`, sk: "COURSE", uniqueId: code };
  }

  if (entity === "grades") {
    const id = String(valueSource.id || "").trim();
    const studentId = String(valueSource.studentId || "").trim();
    const courseCode = String(valueSource.courseCode || "").toUpperCase().trim();

    if (studentId && courseCode) {
      return {
        pk: `GRADE#${studentId}#${courseCode}`,
        sk: "GRADE",
        uniqueId: `${studentId}:${courseCode}`
      };
    }

    if (!id || id.indexOf(":") === -1) {
      throw new Error("For grades, provide id in format studentId:courseCode");
    }

    const parts = id.split(":");
    const sid = (parts[0] || "").trim();
    const ccode = (parts[1] || "").trim().toUpperCase();
    if (!sid || !ccode) throw new Error("Invalid grade id");

    return {
      pk: `GRADE#${sid}#${ccode}`,
      sk: "GRADE",
      uniqueId: `${sid}:${ccode}`
    };
  }

  throw new Error(`Unsupported entity: ${entity}`);
}

function sanitizeInput(entity, payload) {
  const required = REQUIRED_FIELDS[entity] || [];
  const missing = required.filter((field) => payload[field] === undefined || payload[field] === null || payload[field] === "");
  if (missing.length) {
    throw new Error(`Missing required fields: ${missing.join(", ")}`);
  }

  return payload;
}

async function maybeNotifyOnCreate(entity, item) {
  if (entity === "programs" || entity === "courses") {
    await sns
      .publish({
        TopicArn: SNS_TOPIC_ARN,
        Message: JSON.stringify({
          type: `${entity.slice(0, -1)}_created`,
          entity,
          item,
          subject: `New ${entity.slice(0, -1)} added`
        })
      })
      .promise();
  }

  if (entity === "grades") {
    await sqs
      .sendMessage({
        QueueUrl: NOTIFICATIONS_QUEUE_URL,
        MessageBody: JSON.stringify({
          type: "grade_created",
          recipient: item.userEmail,
          subject: `Grade posted for ${item.courseCode}`,
          body: `Hello ${item.studentId}, your grade for ${item.courseCode} is ${item.grade}.`
        })
      })
      .promise();
  }
}

async function listItems(entity) {
  const prefixMap = {
    users: "USER#",
    programs: "PROGRAM#",
    courses: "COURSE#",
    grades: "GRADE#"
  };

  const scanResult = await ddb
    .scan({
      TableName: TABLE_NAME,
      FilterExpression: "begins_with(pk, :prefix)",
      ExpressionAttributeValues: {
        ":prefix": prefixMap[entity]
      }
    })
    .promise();

  return scanResult.Items || [];
}

exports.handler = async (event) => {
  try {
    if (!TABLE_NAME || !ENTITY || !OPERATION) {
      return response(500, { error: "Lambda is missing required environment variables" });
    }

    if (event.httpMethod === "OPTIONS") {
      return response(200, { ok: true });
    }

    if (OPERATION === "list") {
      const items = await listItems(ENTITY);
      return response(200, { entity: ENTITY, count: items.length, items });
    }

    if (OPERATION === "create") {
      const payload = sanitizeInput(ENTITY, parseBody(event));
      const keys = buildKeys(ENTITY, payload);
      const now = new Date().toISOString();

      const item = Object.assign({}, payload, keys, {
        entity: ENTITY,
        createdAt: now,
        updatedAt: now
      });

      await ddb
        .put({
          TableName: TABLE_NAME,
          Item: item,
          ConditionExpression: "attribute_not_exists(pk) AND attribute_not_exists(sk)"
        })
        .promise();

      if (ENTITY !== "users") {
        await maybeNotifyOnCreate(ENTITY, item);
      }

      return response(201, { message: `${ENTITY.slice(0, -1)} created`, item });
    }

    if (OPERATION === "update") {
      const id = event.pathParameters && event.pathParameters.id;
      const payload = sanitizeInput(ENTITY, parseBody(event));
      const keys = buildKeys(ENTITY, Object.assign({}, payload, { id }));
      const allowedFields = Object.keys(payload).filter((f) => ["pk", "sk", "entity", "createdAt"].indexOf(f) === -1);
      if (!allowedFields.length) {
        return response(400, { error: "No updatable fields supplied" });
      }

      const names = { "#updatedAt": "updatedAt" };
      const values = { ":updatedAt": new Date().toISOString() };
      const updates = ["#updatedAt = :updatedAt"];

      allowedFields.forEach((field, index) => {
        const nameKey = `#f${index}`;
        const valueKey = `:v${index}`;
        names[nameKey] = field;
        values[valueKey] = payload[field];
        updates.push(`${nameKey} = ${valueKey}`);
      });

      const updated = await ddb
        .update({
          TableName: TABLE_NAME,
          Key: { pk: keys.pk, sk: keys.sk },
          ConditionExpression: "attribute_exists(pk) AND attribute_exists(sk)",
          UpdateExpression: `SET ${updates.join(", ")}`,
          ExpressionAttributeNames: names,
          ExpressionAttributeValues: values,
          ReturnValues: "ALL_NEW"
        })
        .promise();

      return response(200, { message: `${ENTITY.slice(0, -1)} updated`, item: updated.Attributes });
    }

    if (OPERATION === "delete") {
      const id = event.pathParameters && event.pathParameters.id;
      const keys = buildKeys(ENTITY, { id });
      await ddb
        .delete({
          TableName: TABLE_NAME,
          Key: { pk: keys.pk, sk: keys.sk },
          ConditionExpression: "attribute_exists(pk) AND attribute_exists(sk)"
        })
        .promise();

      return response(200, { message: `${ENTITY.slice(0, -1)} deleted`, id: keys.uniqueId });
    }

    return response(400, { error: `Unsupported operation: ${OPERATION}` });
  } catch (error) {
    if (error.code === "ConditionalCheckFailedException") {
      if (OPERATION === "create") {
        return response(409, { error: `${ENTITY.slice(0, -1)} already exists (duplicate blocked)` });
      }

      return response(404, { error: `${ENTITY.slice(0, -1)} not found` });
    }

    return response(400, { error: error.message || "Unhandled error" });
  }
};
