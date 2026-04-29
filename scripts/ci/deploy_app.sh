#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/ci/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:-all}"
INITIALIZED_STACK_DIRS=()

cleanup_initialized_backends() {
  local stack_dir
  for stack_dir in "${INITIALIZED_STACK_DIRS[@]}"; do
    cleanup_ci_backend_file "${stack_dir}"
  done
}

trap cleanup_initialized_backends EXIT

require_tools() {
  local tool
  for tool in aws docker terraform uv node npm; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "Required tool not found: ${tool}" >&2
      exit 1
    fi
  done
}

install_frontend_dependencies() {
  if [[ -f "${ROOT_DIR}/frontend/package-lock.json" ]]; then
    npm ci --prefix "${ROOT_DIR}/frontend"
  else
    npm install --prefix "${ROOT_DIR}/frontend"
  fi
}

init_stack_for_outputs() {
  local stack="$1"
  local stack_dir
  stack_dir="$(terraform_stack_dir "${stack}")"
  INITIALIZED_STACK_DIRS+=("${stack_dir}")
  prepare_local_state_dependencies "${stack}"
  init_remote_backend "${stack}"
}

deploy_api() {
  echo "Deploying API Lambda"
  init_stack_for_outputs "7_frontend"

  local function_name
  function_name="$(terraform_output_raw "7_frontend" "lambda_function_name")"

  (
    cd "${ROOT_DIR}/backend/api"
    uv run package_docker.py
  )

  aws lambda update-function-code \
    --function-name "${function_name}" \
    --zip-file "fileb://${ROOT_DIR}/backend/api/api_lambda.zip" \
    --publish >/dev/null

  aws lambda wait function-updated --function-name "${function_name}"
  echo "API Lambda updated: ${function_name}"
}

deploy_agents() {
  echo "Deploying agent Lambdas"
  init_stack_for_outputs "6_agents"

  local account_id bucket
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  bucket="alex-lambda-packages-${account_id}"

  (
    cd "${ROOT_DIR}/backend"
    uv run package_docker.py
  )

  local agents_json
  agents_json="$(terraform_output_json "6_agents" "lambda_functions")"

  for agent in planner tagger reporter charter retirement; do
    local function_name zip_path s3_key
    function_name="$(jq -r ".${agent}" <<<"${agents_json}")"
    zip_path="${ROOT_DIR}/backend/${agent}/${agent}_lambda.zip"
    s3_key="${agent}/${agent}_lambda.zip"

    aws s3 cp "${zip_path}" "s3://${bucket}/${s3_key}" >/dev/null
    aws lambda update-function-code \
      --function-name "${function_name}" \
      --s3-bucket "${bucket}" \
      --s3-key "${s3_key}" \
      --publish >/dev/null
    aws lambda wait function-updated --function-name "${function_name}"
    echo "Agent updated: ${function_name}"
  done
}

deploy_frontend() {
  echo "Deploying frontend"
  init_stack_for_outputs "7_frontend"

  require_env NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY

  local bucket distribution_id api_url
  bucket="$(terraform_output_raw "7_frontend" "s3_bucket_name")"
  distribution_id="$(terraform_output_raw "7_frontend" "cloudfront_distribution_id")"
  api_url="${NEXT_PUBLIC_API_URL:-$(terraform_output_raw "7_frontend" "api_gateway_url")}"

  install_frontend_dependencies

  cat > "${ROOT_DIR}/frontend/.env.production.local" <<EOF
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=${NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY}
NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL=${NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL:-/dashboard}
NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL=${NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL:-/dashboard}
NEXT_PUBLIC_API_URL=${api_url}
EOF

  (
    cd "${ROOT_DIR}/frontend"
    npm run build
  )

  aws s3 sync "${ROOT_DIR}/frontend/out/" "s3://${bucket}/" --delete
  aws cloudfront create-invalidation --distribution-id "${distribution_id}" --paths "/*" >/dev/null
  echo "Frontend deployed to s3://${bucket} and CloudFront invalidated"
}

deploy_researcher() {
  echo "Deploying researcher"
  init_stack_for_outputs "4_researcher"

  local ecr_url region service_arn image_tag
  ecr_url="$(terraform_output_raw "4_researcher" "ecr_repository_url")"
  region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  if [[ -z "${region}" ]]; then
    echo "Missing required environment variable: AWS_REGION or AWS_DEFAULT_REGION" >&2
    exit 1
  fi

  aws ecr get-login-password --region "${region}" \
    | docker login --username AWS --password-stdin "${ecr_url}"

  image_tag="${GITHUB_SHA:-manual}"

  (
    cd "${ROOT_DIR}/backend/researcher"
    docker build --platform linux/amd64 -t "${ecr_url}:${image_tag}" -t "${ecr_url}:latest" .
  )

  docker push "${ecr_url}:${image_tag}"
  docker push "${ecr_url}:latest"

  service_arn="$(aws apprunner list-services \
    --region "${region}" \
    --query "ServiceSummaryList[?ServiceName=='alex-researcher'].ServiceArn | [0]" \
    --output text)"

  if [[ -z "${service_arn}" || "${service_arn}" == "None" ]]; then
    echo "App Runner service alex-researcher not found" >&2
    exit 1
  fi

  aws apprunner start-deployment --service-arn "${service_arn}" --region "${region}" >/dev/null
  echo "Researcher deployment started for ${service_arn}"
}

main() {
  require_tools

  case "${TARGET}" in
    api)
      deploy_api
      ;;
    agents)
      deploy_agents
      ;;
    frontend)
      deploy_frontend
      ;;
    researcher)
      deploy_researcher
      ;;
    all)
      deploy_api
      deploy_agents
      deploy_frontend
      deploy_researcher
      ;;
    *)
      echo "Unknown app deploy target: ${TARGET}" >&2
      exit 1
      ;;
  esac
}

main
