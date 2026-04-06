# Terraform setup for AWS Student Tracker

This Terraform stack provisions:

- S3 static website bucket and uploads `index.html`, `styles.css`, and `app.js`.
- API Gateway REST API for `users`, `programs`, `courses`, `grades` with per-entity CRUD routes.
- A dedicated Lambda per entity/CRUD operation (Node.js runtime).
- Cognito User Pool + User Pool Client and API Gateway Cognito authorizer.
- DynamoDB single-table model with conditional writes to block duplicates.
- SNS + SQS + notification Lambda + SES email notifications:
  - No email for created users.
  - New courses/programs email all users.
  - New grades email the targeted user.

## Quick start

```bash
cd terraform
terraform init
terraform apply -var="ses_from_email=verified-sender@example.com"
```

## Notes

- `ses_from_email` must be verified in SES.
- In SES sandbox, recipients also need to be verified.
- Cognito login is required for all CRUD API routes.
- The frontend needs a valid Cognito JWT in `Authorization` header when calling APIs.
