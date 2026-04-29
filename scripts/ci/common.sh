#!/usr/bin/env bash

set -euo pipefail

repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${script_dir}/../.." && pwd
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

terraform_state_key() {
  local stack="$1"
  echo "alex/${stack}/terraform.tfstate"
}

terraform_stack_dir() {
  local root
  root="$(repo_root)"
  echo "${root}/terraform/${1}"
}

create_ci_backend_file() {
  local stack_dir="$1"
  cat > "${stack_dir}/backend.ci.tf" <<'EOF'
terraform {
  backend "s3" {}
}
EOF
}

cleanup_ci_backend_file() {
  local stack_dir="$1"
  rm -f "${stack_dir}/backend.ci.tf"
}

init_remote_backend() {
  local stack="$1"
  local stack_dir
  stack_dir="$(terraform_stack_dir "${stack}")"

  require_env TF_STATE_BUCKET
  require_env TF_STATE_REGION

  create_ci_backend_file "${stack_dir}"

  local -a init_args=(
    "-chdir=${stack_dir}"
    "init"
    "-input=false"
    "-reconfigure"
    "-backend-config=bucket=${TF_STATE_BUCKET}"
    "-backend-config=key=$(terraform_state_key "${stack}")"
    "-backend-config=region=${TF_STATE_REGION}"
    "-backend-config=encrypt=true"
  )

  if [[ -n "${TF_LOCK_TABLE:-}" ]]; then
    init_args+=("-backend-config=dynamodb_table=${TF_LOCK_TABLE}")
  fi

  terraform "${init_args[@]}"
}

download_state_file() {
  local stack="$1"
  local destination="$2"
  local root
  root="$(repo_root)"

  require_env TF_STATE_BUCKET

  mkdir -p "$(dirname "${destination}")"
  aws s3 cp "s3://${TF_STATE_BUCKET}/$(terraform_state_key "${stack}")" "${destination}" >/dev/null
  echo "Downloaded remote state for ${stack} to ${destination#${root}/}"
}

prepare_local_state_dependencies() {
  local stack="$1"
  local root
  root="$(repo_root)"

  if [[ "${stack}" == "7_frontend" ]]; then
    download_state_file "5_database" "${root}/terraform/5_database/terraform.tfstate"
    download_state_file "6_agents" "${root}/terraform/6_agents/terraform.tfstate"
  fi
}

terraform_output_raw() {
  local stack="$1"
  local output_name="$2"
  local stack_dir
  stack_dir="$(terraform_stack_dir "${stack}")"
  terraform -chdir="${stack_dir}" output -raw "${output_name}"
}

terraform_output_json() {
  local stack="$1"
  local output_name="$2"
  local stack_dir
  stack_dir="$(terraform_stack_dir "${stack}")"
  terraform -chdir="${stack_dir}" output -json "${output_name}"
}
