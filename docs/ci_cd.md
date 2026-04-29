# CI/CD for Alex

This repo now has two separate GitHub Actions pipelines:

- `.github/workflows/deploy-infra.yml`
- `.github/workflows/deploy-app.yml`

The split is intentional:

- Infrastructure pipeline manages Terraform only.
- App pipeline updates deployed code only.

That means normal code changes do not need a Terraform apply.

## Why this repo needs a special CI setup

The course repo was designed for local Terraform state in each independent directory. GitHub-hosted runners are ephemeral, so a CI pipeline cannot rely on `terraform.tfstate` being present on disk between runs.

To handle that without rewriting the course Terraform modules:

- the infra workflow injects a temporary CI-only `backend "s3"` block at runtime
- Terraform state is stored remotely in S3
- when `terraform/7_frontend` runs, the CI script also downloads the `5_database` and `6_agents` state files into the local paths that stack expects

This keeps the checked-in Terraform code close to the course while making hosted CI practical.

## Required GitHub configuration

Repository variables:

- `AWS_REGION`
- `TF_STATE_REGION`

Repository secrets:

- `AWS_GITHUB_ROLE_ARN`
- `TF_STATE_BUCKET`
- `TF_LOCK_TABLE` optional but recommended
- `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY`
- `NEXT_PUBLIC_API_URL` optional

Recommended AWS setup:

- use GitHub OIDC with an IAM role for Actions
- store Terraform state in an S3 bucket
- use a DynamoDB table for state locking

## Infrastructure pipeline

Manual trigger:

1. Open `Deploy Infrastructure`
2. Choose a stack like `5_database` or `6_agents`
3. Choose `plan` or `apply`

The workflow runs:

- `terraform init` against the CI S3 backend
- `terraform fmt -check`
- `terraform validate`
- `terraform plan`
- optional `terraform apply`

Important:

- apply the stacks in the normal project order
- `7_frontend` depends on the state outputs from `5_database` and `6_agents`

## App pipeline

Manual trigger or push to `main`.

Targets:

- `api`
- `agents`
- `frontend`
- `researcher`
- `all`

What each target does:

- `api`: packages `backend/api` and runs `aws lambda update-function-code`
- `agents`: packages the five agent Lambdas, uploads zip files to the Lambda package bucket, then updates Lambda code
- `frontend`: builds the static Next.js app, syncs `frontend/out` to S3, invalidates CloudFront
- `researcher`: builds and pushes the Docker image to ECR, then starts an App Runner deployment

## Recommended deployment order

Initial environment bootstrap:

1. `5_database`
2. `6_agents`
3. `7_frontend`
4. `4_researcher`
5. other stacks as needed

Normal code-only delivery after infra exists:

1. run `Deploy App` for `api`, `agents`, `frontend`, or `researcher`

## Notes

- `terraform/7_frontend/outputs.tf` now exposes `cloudfront_distribution_id` so the app workflow can invalidate CloudFront directly.
- The app workflow reads infrastructure outputs, but it does not modify Terraform-managed resources.
- If you later migrate all stacks to true remote-state references instead of local `terraform_remote_state`, the CI scripts can be simplified.
