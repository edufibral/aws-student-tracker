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
  bucket_name = var.website_bucket_name != "" ? var.website_bucket_name : "${local.name_prefix}-frontend"

  endpoint_lambdas = {
    user = {
      path_part    = "user"
      source_dir   = "${path.module}/lambda/user"
      handler      = "index.handler"
      runtime      = "nodejs20.x"
      function_key = "user"
    }
    program = {
      path_part    = "program"
      source_dir   = "${path.module}/lambda/program"
      handler      = "index.handler"
      runtime      = "nodejs20.x"
      function_key = "program"
    }
    course = {
      path_part    = "course"
      source_dir   = "${path.module}/lambda/course"
      handler      = "index.handler"
      runtime      = "nodejs20.x"
      function_key = "course"
    }
    grade = {
      path_part    = "grade"
      source_dir   = "${path.module}/lambda/grade"
      handler      = "index.handler"
      runtime      = "nodejs20.x"
      function_key = "grade"
    }
  }

  methods_root = {
    get    = "GET"
    post   = "POST"
    option = "OPTIONS"
  }

  methods_with_id = {
    put    = "PUT"
    delete = "DELETE"
    option = "OPTIONS"
  }
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
}

resource "aws_cognito_user_pool" "main" {
  name                     = "${local.name_prefix}-user-pool"
  auto_verified_attributes = ["email"]
  username_attributes      = ["email"]

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

  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]
  prevent_user_existence_errors = "ENABLED"
}

resource "aws_sns_topic" "major_events" {
  name = "${local.name_prefix}-major-events"
}

resource "aws_sqs_queue" "notifications" {
  name                       = "${local.name_prefix}-notifications"
  visibility_timeout_seconds = 120
}

data "aws_iam_policy_document" "notifications_queue_policy" {
  statement {
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

resource "aws_sqs_queue_policy" "notifications" {
  queue_url = aws_sqs_queue.notifications.id
  policy    = data.aws_iam_policy_document.notifications_queue_policy.json
}

resource "aws_sns_topic_subscription" "major_events_to_queue" {
  topic_arn = aws_sns_topic.major_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.notifications.arn
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "endpoint_lambda" {
  for_each = local.endpoint_lambdas

  name               = "${local.name_prefix}-${each.key}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role" "notify_lambda" {
  name               = "${local.name_prefix}-notify-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "endpoint_lambda" {
  for_each = local.endpoint_lambdas

  statement {
    actions = ["dynamodb:Scan", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
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
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "endpoint_lambda" {
  for_each = local.endpoint_lambdas

  role   = aws_iam_role.endpoint_lambda[each.key].id
  name   = "${local.name_prefix}-${each.key}-lambda-policy"
  policy = data.aws_iam_policy_document.endpoint_lambda[each.key].json
}

data "aws_iam_policy_document" "notify_lambda" {
  statement {
    actions   = ["dynamodb:Scan"]
    resources = [aws_dynamodb_table.tracker.arn]
  }

  statement {
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }

  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "notify_lambda" {
  role   = aws_iam_role.notify_lambda.id
  name   = "${local.name_prefix}-notify-lambda-policy"
  policy = data.aws_iam_policy_document.notify_lambda.json
}

resource "terraform_data" "install_lambda_dependencies" {
  for_each = merge(local.endpoint_lambdas, {
    notify = {
      source_dir = "${path.module}/lambda/notify"
    }
  })

  triggers_replace = {
    package_json = filemd5("${each.value.source_dir}/package.json")
  }

  provisioner "local-exec" {
    command = "cd ${each.value.source_dir} && npm install --omit=dev"
  }
}

data "archive_file" "endpoint_lambda" {
  for_each = local.endpoint_lambdas

  type        = "zip"
  source_dir  = each.value.source_dir
  output_path = "${path.module}/build/${each.key}.zip"

  depends_on = [terraform_data.install_lambda_dependencies]
}

data "archive_file" "notify_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/notify"
  output_path = "${path.module}/build/notify.zip"

  depends_on = [terraform_data.install_lambda_dependencies]
}

resource "aws_lambda_function" "endpoint" {
  for_each = local.endpoint_lambdas

  function_name    = "${local.name_prefix}-${each.key}"
  role             = aws_iam_role.endpoint_lambda[each.key].arn
  runtime          = each.value.runtime
  handler          = each.value.handler
  filename         = data.archive_file.endpoint_lambda[each.key].output_path
  source_code_hash = data.archive_file.endpoint_lambda[each.key].output_base64sha256
  timeout          = 20

  environment {
    variables = {
      TABLE_NAME                = aws_dynamodb_table.tracker.name
      MAJOR_EVENTS_TOPIC_ARN    = aws_sns_topic.major_events.arn
      NOTIFICATIONS_QUEUE_URL   = aws_sqs_queue.notifications.id
    }
  }
}

resource "aws_lambda_function" "notify" {
  function_name    = "${local.name_prefix}-notify"
  role             = aws_iam_role.notify_lambda.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.notify_lambda.output_path
  source_code_hash = data.archive_file.notify_lambda.output_base64sha256
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
}

resource "aws_api_gateway_rest_api" "api" {
  name = "${local.name_prefix}-api"
}

resource "aws_api_gateway_authorizer" "cognito" {
  name            = "${local.name_prefix}-cognito"
  rest_api_id     = aws_api_gateway_rest_api.api.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [aws_cognito_user_pool.main.arn]
  identity_source = "method.request.header.Authorization"
}

resource "aws_api_gateway_resource" "entity" {
  for_each = local.endpoint_lambdas

  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = each.value.path_part
}

resource "aws_api_gateway_resource" "entity_id" {
  for_each = local.endpoint_lambdas

  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.entity[each.key].id
  path_part   = "{id}"
}

locals {
  root_methods = {
    for pair in setproduct(keys(local.endpoint_lambdas), keys(local.methods_root)) :
    "${pair[0]}_${pair[1]}" => {
      entity = pair[0]
      method = local.methods_root[pair[1]]
    }
  }

  id_methods = {
    for pair in setproduct(keys(local.endpoint_lambdas), keys(local.methods_with_id)) :
    "${pair[0]}_${pair[1]}" => {
      entity = pair[0]
      method = local.methods_with_id[pair[1]]
    }
  }
}

resource "aws_api_gateway_method" "root" {
  for_each = local.root_methods

  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.entity[each.value.entity].id
  http_method   = each.value.method
  authorization = each.value.method == "OPTIONS" ? "NONE" : "COGNITO_USER_POOLS"
  authorizer_id = each.value.method == "OPTIONS" ? null : aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_method" "id" {
  for_each = local.id_methods

  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.entity_id[each.value.entity].id
  http_method   = each.value.method
  authorization = each.value.method == "OPTIONS" ? "NONE" : "COGNITO_USER_POOLS"
  authorizer_id = each.value.method == "OPTIONS" ? null : aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "root_lambda" {
  for_each = { for k, v in local.root_methods : k => v if v.method != "OPTIONS" }

  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.entity[each.value.entity].id
  http_method             = aws_api_gateway_method.root[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.endpoint[each.value.entity].invoke_arn
}

resource "aws_api_gateway_integration" "id_lambda" {
  for_each = { for k, v in local.id_methods : k => v if v.method != "OPTIONS" }

  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.entity_id[each.value.entity].id
  http_method             = aws_api_gateway_method.id[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.endpoint[each.value.entity].invoke_arn
}

resource "aws_api_gateway_integration" "root_options" {
  for_each = { for k, v in local.root_methods : k => v if v.method == "OPTIONS" }

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity[each.value.entity].id
  http_method = aws_api_gateway_method.root[each.key].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "root_options" {
  for_each = { for k, v in local.root_methods : k => v if v.method == "OPTIONS" }

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity[each.value.entity].id
  http_method = aws_api_gateway_method.root[each.key].http_method
  status_code = "200"

  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "root_options" {
  for_each = { for k, v in local.root_methods : k => v if v.method == "OPTIONS" }

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity[each.value.entity].id
  http_method = aws_api_gateway_method.root[each.key].http_method
  status_code = aws_api_gateway_method_response.root_options[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_api_gateway_integration" "id_options" {
  for_each = { for k, v in local.id_methods : k => v if v.method == "OPTIONS" }

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity_id[each.value.entity].id
  http_method = aws_api_gateway_method.id[each.key].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "id_options" {
  for_each = { for k, v in local.id_methods : k => v if v.method == "OPTIONS" }

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity_id[each.value.entity].id
  http_method = aws_api_gateway_method.id[each.key].http_method
  status_code = "200"

  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "id_options" {
  for_each = { for k, v in local.id_methods : k => v if v.method == "OPTIONS" }

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.entity_id[each.value.entity].id
  http_method = aws_api_gateway_method.id[each.key].http_method
  status_code = aws_api_gateway_method_response.id_options[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_lambda_permission" "api_invoke" {
  for_each = local.endpoint_lambdas

  statement_id  = "AllowInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.endpoint[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*/${each.value.path_part}*"
}

resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_integration.root_lambda,
      aws_api_gateway_integration.id_lambda,
      aws_api_gateway_integration.root_options,
      aws_api_gateway_integration.id_options
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "stage" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deploy.id
  stage_name    = var.environment
}

resource "aws_s3_bucket" "frontend" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document { suffix = "index.html" }
  error_document { key = "index.html" }
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
  bucket     = aws_s3_bucket.frontend.id
  policy     = data.aws_iam_policy_document.frontend_public_read.json
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
