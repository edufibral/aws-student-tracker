terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  entities = {
    users = {
      path_part = "users"
      endpoint  = "users"
    }
    programs = {
      path_part = "programs"
      endpoint  = "programs"
    }
    courses = {
      path_part = "courses"
      endpoint  = "courses"
    }
    grades = {
      path_part = "grades"
      endpoint  = "grades"
    }
  }

  crud_operations = {
    list = {
      method       = "GET"
      use_id_route = false
    }
    create = {
      method       = "POST"
      use_id_route = false
    }
    update = {
      method       = "PUT"
      use_id_route = true
    }
    delete = {
      method       = "DELETE"
      use_id_route = true
    }
  }

  lambda_matrix = {
    for pair in setproduct(keys(local.entities), keys(local.crud_operations)) :
    "${pair[0]}_${pair[1]}" => {
      entity    = pair[0]
      operation = pair[1]
      method    = local.crud_operations[pair[1]].method
      use_id    = local.crud_operations[pair[1]].use_id_route
    }
  }

  bucket_name = var.website_bucket_name != "" ? var.website_bucket_name : "${local.name_prefix}-frontend"
}

resource "aws_dynamodb_table" "tracker" {
  name         = "${local.name_prefix}-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  tags = {
    Project = var.project_name
    Env     = var.environment
  }
}

resource "aws_cognito_user_pool" "main" {
  name                     = "${local.name_prefix}-user-pool"
  auto_verified_attributes = ["email"]

  username_attributes = ["email"]

  password_policy {
    minimum_length    = 10
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name_prefix}-web-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = false
  explicit_auth_flows                  = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]
  prevent_user_existence_errors        = "ENABLED"
  allowed_oauth_flows_user_pool_client = false
}

resource "aws_sns_topic" "major_events" {
  name = "${local.name_prefix}-major-events"
}

resource "aws_sqs_queue" "notifications" {
  name                       = "${local.name_prefix}-notifications"
  visibility_timeout_seconds = 120
}

resource "aws_sqs_queue_policy" "notifications" {
  queue_url = aws_sqs_queue.notifications.id
  policy    = data.aws_iam_policy_document.notifications_queue_policy.json
}

data "aws_iam_policy_document" "notifications_queue_policy" {
  statement {
    sid    = "AllowSnsSendMessage"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.notifications.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.major_events.arn]
    }
  }
}

resource "aws_sns_topic_subscription" "major_events_to_queue" {
  topic_arn = aws_sns_topic.major_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.notifications.arn
}

resource "aws_iam_role" "crud_lambda" {
  name = "${local.name_prefix}-crud-lambda-role"

  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role" "notify_lambda" {
  name = "${local.name_prefix}-notify-lambda-role"

  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "crud_lambda" {
  name = "${local.name_prefix}-crud-lambda-policy"
  role = aws_iam_role.crud_lambda.id

  policy = data.aws_iam_policy_document.crud_lambda.json
}

data "aws_iam_policy_document" "crud_lambda" {
  statement {
    actions = [
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Scan"
    ]
    resources = [aws_dynamodb_table.tracker.arn]
  }

  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.major_events.arn]
  }

  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.notifications.arn]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "notify_lambda" {
  name = "${local.name_prefix}-notify-lambda-policy"
  role = aws_iam_role.notify_lambda.id

  policy = data.aws_iam_policy_document.notify_lambda.json
}

data "aws_iam_policy_document" "notify_lambda" {
  statement {
    actions = ["dynamodb:Scan"]
    resources = [aws_dynamodb_table.tracker.arn]
  }

  statement {
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail"
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

data "archive_file" "crud_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/crud"
  output_path = "${path.module}/build/crud.zip"
}

data "archive_file" "notify_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/notify"
  output_path = "${path.module}/build/notify.zip"
}

resource "aws_lambda_function" "crud" {
  for_each = local.lambda_matrix

  function_name    = "${local.name_prefix}-${each.value.entity}-${each.value.operation}"
  role             = aws_iam_role.crud_lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.crud_zip.output_path
  source_code_hash = data.archive_file.crud_zip.output_base64sha256
  timeout          = 20

  environment {
    variables = {
      TABLE_NAME               = aws_dynamodb_table.tracker.name
      ENTITY                   = each.value.entity
      OPERATION                = each.value.operation
      SNS_TOPIC_ARN            = aws_sns_topic.major_events.arn
      NOTIFICATIONS_QUEUE_URL  = aws_sqs_queue.notifications.id
    }
  }
}

resource "aws_lambda_function" "notify" {
  function_name    = "${local.name_prefix}-notifications"
  role             = aws_iam_role.notify_lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.notify_zip.output_path
  source_code_hash = data.archive_file.notify_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      TABLE_NAME     = aws_dynamodb_table.tracker.name
      SES_FROM_EMAIL = var.ses_from_email
    }
  }
}

resource "aws_lambda_event_source_mapping" "notify_from_queue" {
  event_source_arn = aws_sqs_queue.notifications.arn
  function_name    = aws_lambda_function.notify.arn
  batch_size       = 10
  enabled          = true
}

resource "aws_api_gateway_rest_api" "api" {
  name        = "${local.name_prefix}-api"
  description = "Student tracker CRUD API"
}

resource "aws_api_gateway_authorizer" "cognito" {
  name            = "${local.name_prefix}-cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.api.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [aws_cognito_user_pool.main.arn]
  identity_source = "method.request.header.Authorization"
}

resource "aws_api_gateway_resource" "entity" {
  for_each = local.entities

  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = each.value.path_part
}

resource "aws_api_gateway_resource" "entity_id" {
  for_each = local.entities

  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.entity[each.key].id
  path_part   = "{id}"
}

resource "aws_api_gateway_method" "crud" {
  for_each = local.lambda_matrix

  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = each.value.use_id ? aws_api_gateway_resource.entity_id[each.value.entity].id : aws_api_gateway_resource.entity[each.value.entity].id
  http_method   = each.value.method
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "crud" {
  for_each = local.lambda_matrix

  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = each.value.use_id ? aws_api_gateway_resource.entity_id[each.value.entity].id : aws_api_gateway_resource.entity[each.value.entity].id
  http_method             = aws_api_gateway_method.crud[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.crud[each.key].invoke_arn
}

resource "aws_lambda_permission" "allow_apigw" {
  for_each = local.lambda_matrix

  statement_id  = "AllowApiGatewayInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.crud[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/${each.value.method}/${local.entities[each.value.entity].path_part}${each.value.use_id ? "/*" : ""}"
}

resource "aws_api_gateway_method" "options_entity" {
  for_each = local.entities

  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.entity[each.key].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_entity" {
  for_each = local.entities

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity[each.key].id
  http_method = aws_api_gateway_method.options_entity[each.key].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_entity" {
  for_each = local.entities

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity[each.key].id
  http_method = aws_api_gateway_method.options_entity[each.key].http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_entity" {
  for_each = local.entities

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity[each.key].id
  http_method = aws_api_gateway_method.options_entity[each.key].http_method
  status_code = aws_api_gateway_method_response.options_entity[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_api_gateway_method" "options_entity_id" {
  for_each = local.entities

  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.entity_id[each.key].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_entity_id" {
  for_each = local.entities

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity_id[each.key].id
  http_method = aws_api_gateway_method.options_entity_id[each.key].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_entity_id" {
  for_each = local.entities

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity_id[each.key].id
  http_method = aws_api_gateway_method.options_entity_id[each.key].http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_entity_id" {
  for_each = local.entities

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity_id[each.key].id
  http_method = aws_api_gateway_method.options_entity_id[each.key].http_method
  status_code = aws_api_gateway_method_response.options_entity_id[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_integration.crud,
      aws_api_gateway_integration.options_entity,
      aws_api_gateway_integration.options_entity_id
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.crud,
    aws_api_gateway_integration.options_entity,
    aws_api_gateway_integration.options_entity_id
  ]
}

resource "aws_api_gateway_stage" "dev" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deploy.id
  stage_name    = var.environment
}

resource "aws_s3_bucket" "frontend" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "frontend_public_read" {
  statement {
    sid    = "PublicReadForWebsite"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_public_read.json

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

resource "aws_s3_object" "frontend_assets" {
  for_each = {
    "index.html" = "${path.module}/../index.html"
    "app.js"     = "${path.module}/../app.js"
    "styles.css" = "${path.module}/../styles.css"
  }

  bucket       = aws_s3_bucket.frontend.id
  key          = each.key
  source       = each.value
  etag         = filemd5(each.value)
  content_type = each.key == "index.html" ? "text/html" : (each.key == "styles.css" ? "text/css" : "application/javascript")
}
