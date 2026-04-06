output "api_base_url" {
  description = "Base URL for API calls"
  value       = "${aws_api_gateway_stage.dev.invoke_url}"
}

output "api_routes" {
  value = {
    users    = "${aws_api_gateway_stage.dev.invoke_url}/users"
    programs = "${aws_api_gateway_stage.dev.invoke_url}/programs"
    courses  = "${aws_api_gateway_stage.dev.invoke_url}/courses"
    grades   = "${aws_api_gateway_stage.dev.invoke_url}/grades"
  }
}

output "frontend_website_url" {
  description = "S3 static website URL"
  value       = aws_s3_bucket_website_configuration.frontend.website_endpoint
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_web_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "notifications_queue_url" {
  value = aws_sqs_queue.notifications.id
}
