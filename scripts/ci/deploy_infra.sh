#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/ci/common.sh
source "${SCRIPT_DIR}/common.sh"

STACK="${1:-}"
ACTION="${2:-plan}"

if [[ -z "${STACK}" ]]; then
  echo "Usage: bash scripts/ci/deploy_infra.sh <stack> [plan|apply]" >&2
  exit 1
fi

if [[ "${ACTION}" != "plan" && "${ACTION}" != "apply" ]]; then
  echo "Invalid action: ${ACTION}. Use plan or apply." >&2
  exit 1
fi

STACK_DIR="$(terraform_stack_dir "${STACK}")"
if [[ ! -d "${STACK_DIR}" ]]; then
  echo "Unknown terraform stack: ${STACK}" >&2
  exit 1
fi

trap 'cleanup_ci_backend_file "${STACK_DIR}"' EXIT

prepare_local_state_dependencies "${STACK}"
init_remote_backend "${STACK}"

terraform -chdir="${STACK_DIR}" fmt -check
terraform -chdir="${STACK_DIR}" validate

PLAN_FILE="tfplan"
terraform -chdir="${STACK_DIR}" plan -input=false -out="${PLAN_FILE}"

if [[ "${ACTION}" == "apply" ]]; then
  terraform -chdir="${STACK_DIR}" apply -input=false -auto-approve "${PLAN_FILE}"
fi
