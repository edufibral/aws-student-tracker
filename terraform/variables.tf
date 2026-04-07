variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Project short name"
  type        = string
  default     = "aws-student-tracker"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "ses_from_email" {
  description = "Verified SES sender email"
  type        = string
}

variable "website_bucket_name" {
  description = "Optional override for S3 website bucket name"
  type        = string
  default     = ""
}
