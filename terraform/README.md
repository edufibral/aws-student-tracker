# Terraform setup for AWS Student Tracker

This stack provisions:

- S3 static website bucket and uploads `index.html`, `styles.css`, `app.js`.
- API Gateway REST API with singular entity routes:
  - `/user`
  - `/program`
  - `/course`
  - `/grade`
- One dedicated endpoint Lambda per route (`user`, `program`, `course`, `grade`) using Node.js 20 + AWS SDK v3.
- Separate notification Lambda for SES emails from SQS events.
- Cognito User Pool + User Pool Client + API Gateway Cognito authorizer.
- DynamoDB single-table model with conditional write guards to block duplicates.
- SNS + SQS event pipeline for creation notifications.

## Lambda packaging

Each Lambda folder includes:

- `index.mjs`
- `package.json`

Terraform runs `npm install --omit=dev` in each lambda folder before zipping deployment artifacts.

## Quick start

```bash
cd terraform
terraform init
terraform apply -var="ses_from_email=verified-sender@example.com"
```

## Notes

- `ses_from_email` must be SES-verified.
- In SES sandbox, recipients must also be verified.
- API routes use Cognito authorizer and require a valid JWT in `Authorization`.
