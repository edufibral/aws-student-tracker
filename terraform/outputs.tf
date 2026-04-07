output "api_base_url" {
  value = aws_api_gateway_stage.stage.invoke_url
}

output "api_routes" {
  value = {
    user    = "${aws_api_gateway_stage.stage.invoke_url}/user"
    program = "${aws_api_gateway_stage.stage.invoke_url}/program"
    course  = "${aws_api_gateway_stage.stage.invoke_url}/course"
    grade   = "${aws_api_gateway_stage.stage.invoke_url}/grade"
  }
}

output "frontend_website_url" {
  value = aws_s3_bucket_website_configuration.frontend.website_endpoint
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_web_client_id" {
  value = aws_cognito_user_pool_client.web.id
}
