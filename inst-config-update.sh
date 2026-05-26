#!/usr/bin/env bash
set -euo pipefail



usage() {
  cat >&2 <<USAGE
Usage:
  $0 --new-instance-config-id <ocid>
     --compartment-id <ocid>
     --instance-pool-id <ocid>
     --lb-id <ocid>
     --backend-set-name <name>
     --app-port <port>

You may also pass the new instance configuration as the first positional arg:
  $0 <new_instance_configuration_ocid> --compartment-id <ocid> --instance-pool-id <ocid> ...

Required values, via flags or environment variables:
  --new-instance-config-id, NEW_INSTANCE_CONFIG_ID
  --compartment-id,          COMPARTMENT_ID
  --instance-pool-id, --pool-id, INSTANCE_POOL_ID
  --lb-id,                   LB_ID
  --backend-set-name,        BACKEND_SET_NAME
  --app-port,                APP_PORT

Optional source file:
  --env-file <path>          Source variables from a file first; CLI flags override it.
  --no-env-file              Ignore ENV_FILE and do not source any env file. Default.

Optional rollout controls:
  --target-pool-size <N>     Defaults to current pool target size.
  --surge-by <N>             Default: 1
  --drain-seconds <N>        Default: 120
  --health-wait-attempts <N> Default: 80
  --replacement-method <mode> terminate or detach. Default: terminate
  --reset-rollout-state      Recapture old instance list for a fresh rollout.
  --rollout-state-dir <path> Resume state directory.
  --workdir <path>           Where rollout state is stored by default.
  --delete-stale-backend <true|false> Default: true
  --lb-ip <ip>               Optional, only used for final sample curl.
  --listener-port <port>     Optional, only used for final sample curl.

Example with no outputs.env:
  $0 --new-instance-config-id ocid1.instanceconfiguration.oc1..new
     --compartment-id ocid1.compartment.oc1..aaaa
     --instance-pool-id ocid1.instancepool.oc1..aaaa
     --lb-id ocid1.loadbalancer.oc1..aaaa
     --backend-set-name pool-lb-demo-backend-set
     --app-port 8080
     --reset-rollout-state
USAGE
}

have() {
  command -v "$1" >/dev/null 2>&1
}

required() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: $name is required" >&2
    MISSING_REQUIRED=true
  fi
}

need_arg() {
  local opt="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "ERROR: $opt requires a value" >&2
    usage
    exit 1
  fi
}

retry_sleep() {
  local attempt="$1"
  local seconds=$((attempt * 20))
  if (( seconds > 120 )); then
    seconds=120
  fi
  echo "Sleeping ${seconds}s before retry..." >&2
  sleep "$seconds"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="2026-05-18-no-env-file-required"
DEFAULT_ENV_FILE="$SCRIPT_DIR/outputs.env"
ENV_FILE_EXPLICIT=false
USE_ENV_FILE=false

# By default, do not source outputs.env. This keeps CLI-only usage independent of
# any stale ENV_FILE value in the caller's shell. Users can opt in with --env-file.
if [[ -n "${ENV_FILE:-}" ]]; then
  ENV_FILE_EXPLICIT=true
else
  ENV_FILE="$DEFAULT_ENV_FILE"
fi

# Pre-scan only env-file options so a file can be sourced before full arg parsing.
pre_args=("$@")
i=0
while (( i < ${#pre_args[@]} )); do
  arg="${pre_args[$i]}"
  case "$arg" in
    --env-file=*)
      ENV_FILE="${arg#*=}"
      ENV_FILE_EXPLICIT=true
      USE_ENV_FILE=true
      ;;
    --env-file)
      i=$((i + 1))
      if (( i >= ${#pre_args[@]} )); then
        echo "ERROR: --env-file requires a value" >&2
        exit 1
      fi
      ENV_FILE="${pre_args[$i]}"
      ENV_FILE_EXPLICIT=true
      USE_ENV_FILE=true
      ;;
    --no-env-file)
      USE_ENV_FILE=false
      ENV_FILE_EXPLICIT=false
      ;;
  esac
  i=$((i + 1))
done

if [[ "$USE_ENV_FILE" == "true" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  elif [[ "$ENV_FILE_EXPLICIT" == "true" ]]; then
    echo "ERROR: requested env file does not exist: $ENV_FILE" >&2
    echo "Use --no-env-file and pass variables as flags, or provide a valid --env-file path." >&2
    exit 1
  fi
fi

# Parse full CLI. Values provided here override env-file and existing env vars.
POSITIONAL_CONFIG_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --env-file)
      need_arg "$1" "${2:-}"
      shift 2
      continue
      ;;
    --env-file=*)
      shift
      continue
      ;;
    --no-env-file)
      shift
      continue
      ;;
    --new-instance-config-id)
      need_arg "$1" "${2:-}"
      NEW_INSTANCE_CONFIG_ID="$2"
      shift 2
      ;;
    --new-instance-config-id=*)
      NEW_INSTANCE_CONFIG_ID="${1#*=}"
      shift
      ;;
    --compartment-id)
      need_arg "$1" "${2:-}"
      COMPARTMENT_ID="$2"
      shift 2
      ;;
    --compartment-id=*)
      COMPARTMENT_ID="${1#*=}"
      shift
      ;;
    --instance-pool-id|--pool-id)
      need_arg "$1" "${2:-}"
      INSTANCE_POOL_ID="$2"
      shift 2
      ;;
    --instance-pool-id=*|--pool-id=*)
      INSTANCE_POOL_ID="${1#*=}"
      shift
      ;;
    --lb-id|--load-balancer-id)
      need_arg "$1" "${2:-}"
      LB_ID="$2"
      shift 2
      ;;
    --lb-id=*|--load-balancer-id=*)
      LB_ID="${1#*=}"
      shift
      ;;
    --backend-set-name)
      need_arg "$1" "${2:-}"
      BACKEND_SET_NAME="$2"
      shift 2
      ;;
    --backend-set-name=*)
      BACKEND_SET_NAME="${1#*=}"
      shift
      ;;
    --app-port|--backend-port)
      need_arg "$1" "${2:-}"
      APP_PORT="$2"
      shift 2
      ;;
    --app-port=*|--backend-port=*)
      APP_PORT="${1#*=}"
      shift
      ;;
    --target-pool-size)
      need_arg "$1" "${2:-}"
      TARGET_POOL_SIZE="$2"
      shift 2
      ;;
    --target-pool-size=*)
      TARGET_POOL_SIZE="${1#*=}"
      shift
      ;;
    --surge-by)
      need_arg "$1" "${2:-}"
      SURGE_BY="$2"
      shift 2
      ;;
    --surge-by=*)
      SURGE_BY="${1#*=}"
      shift
      ;;
    --drain-seconds)
      need_arg "$1" "${2:-}"
      DRAIN_SECONDS="$2"
      shift 2
      ;;
    --drain-seconds=*)
      DRAIN_SECONDS="${1#*=}"
      shift
      ;;
    --health-wait-attempts)
      need_arg "$1" "${2:-}"
      HEALTH_WAIT_ATTEMPTS="$2"
      shift 2
      ;;
    --health-wait-attempts=*)
      HEALTH_WAIT_ATTEMPTS="${1#*=}"
      shift
      ;;
    --oci-max-retries)
      need_arg "$1" "${2:-}"
      OCI_MAX_RETRIES="$2"
      shift 2
      ;;
    --oci-max-retries=*)
      OCI_MAX_RETRIES="${1#*=}"
      shift
      ;;
    --replacement-method)
      need_arg "$1" "${2:-}"
      REPLACEMENT_METHOD="$2"
      shift 2
      ;;
    --replacement-method=*)
      REPLACEMENT_METHOD="${1#*=}"
      shift
      ;;
    --reset-rollout-state)
      RESET_ROLLOUT_STATE=true
      shift
      ;;
    --reset-rollout-state=*)
      RESET_ROLLOUT_STATE="${1#*=}"
      shift
      ;;
    --rollout-state-dir)
      need_arg "$1" "${2:-}"
      ROLLOUT_STATE_DIR="$2"
      shift 2
      ;;
    --rollout-state-dir=*)
      ROLLOUT_STATE_DIR="${1#*=}"
      shift
      ;;
    --workdir)
      need_arg "$1" "${2:-}"
      WORKDIR="$2"
      shift 2
      ;;
    --workdir=*)
      WORKDIR="${1#*=}"
      shift
      ;;
    --delete-stale-backend)
      need_arg "$1" "${2:-}"
      DELETE_STALE_BACKEND="$2"
      shift 2
      ;;
    --delete-stale-backend=*)
      DELETE_STALE_BACKEND="${1#*=}"
      shift
      ;;
    --lb-ip)
      need_arg "$1" "${2:-}"
      LB_IP="$2"
      shift 2
      ;;
    --lb-ip=*)
      LB_IP="${1#*=}"
      shift
      ;;
    --listener-port)
      need_arg "$1" "${2:-}"
      LISTENER_PORT="$2"
      shift 2
      ;;
    --listener-port=*)
      LISTENER_PORT="${1#*=}"
      shift
      ;;
    --*)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$POSITIONAL_CONFIG_ID" ]]; then
        POSITIONAL_CONFIG_ID="$1"
        shift
      else
        echo "ERROR: unexpected positional argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

NEW_INSTANCE_CONFIG_ID="${NEW_INSTANCE_CONFIG_ID:-$POSITIONAL_CONFIG_ID}"
INSTANCE_POOL_ID="${INSTANCE_POOL_ID:-${POOL_ID:-}}"
APP_PORT="${APP_PORT:-${BACKEND_PORT:-}}"

if [[ -z "${NEW_INSTANCE_CONFIG_ID:-}" ]]; then
  usage
  exit 1
fi

if ! have oci; then echo "ERROR: oci CLI is required" >&2; exit 1; fi
if ! have jq; then echo "ERROR: jq is required" >&2; exit 1; fi

MISSING_REQUIRED=false
required COMPARTMENT_ID
required INSTANCE_POOL_ID
required LB_ID
required BACKEND_SET_NAME
required APP_PORT
if [[ "$MISSING_REQUIRED" == "true" ]]; then
  echo >&2
  usage
  exit 1
fi

DRAIN_SECONDS="${DRAIN_SECONDS:-120}"
HEALTH_WAIT_ATTEMPTS="${HEALTH_WAIT_ATTEMPTS:-80}"
DETACH_ATTEMPTS="${DETACH_ATTEMPTS:-5}"
TERMINATE_ATTEMPTS="${TERMINATE_ATTEMPTS:-5}"
SCALE_UPDATE_ATTEMPTS="${SCALE_UPDATE_ATTEMPTS:-8}"
OCI_MAX_RETRIES="${OCI_MAX_RETRIES:-8}"
SURGE_BY="${SURGE_BY:-1}"
REPLACEMENT_METHOD="${REPLACEMENT_METHOD:-terminate}"
DELETE_STALE_BACKEND="${DELETE_STALE_BACKEND:-true}"

case "$REPLACEMENT_METHOD" in
  terminate|detach) ;;
  *) echo "ERROR: REPLACEMENT_METHOD must be terminate or detach" >&2; exit 1 ;;
esac

WORKDIR="${WORKDIR:-$SCRIPT_DIR}"
ROLLOUT_STATE_DIR="${ROLLOUT_STATE_DIR:-$WORKDIR/rolling-replace-state}"
OLD_IDS_FILE="$ROLLOUT_STATE_DIR/old-instance-ids.txt"
DONE_IDS_FILE="$ROLLOUT_STATE_DIR/done-instance-ids.txt"
STEADY_SIZE_FILE="$ROLLOUT_STATE_DIR/steady-size.txt"
CONFIG_ID_FILE="$ROLLOUT_STATE_DIR/new-instance-config-id.txt"

pool_size() {
  oci compute-management instance-pool get \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --query 'data.size' \
    --raw-output
}

pool_state() {
  oci compute-management instance-pool get \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --query 'data."lifecycle-state"' \
    --raw-output 2>/dev/null || true
}

wait_pool_running() {
  local state=""
  local i
  echo "Waiting for instance pool to be RUNNING..."
  for i in $(seq 1 120); do
    state="$(pool_state)"
    echo "  pool state: ${state:-unknown}"
    if [[ "$state" == "RUNNING" ]]; then
      return 0
    fi
    sleep 10
  done
  echo "ERROR: instance pool did not return to RUNNING." >&2
  return 1
}

validate_new_instance_config() {
  echo "Validating new instance configuration exists..."
  oci compute-management instance-configuration get \
    --instance-configuration-id "$NEW_INSTANCE_CONFIG_ID" >/dev/null
}

list_pool_instances_json() {
  oci compute-management instance-pool list-instances \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --all
}

list_active_pool_instance_ids() {
  list_pool_instances_json \
  | jq -r '.data[] | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING") | .id'
}

active_pool_count() {
  list_pool_instances_json \
  | jq '[.data[] | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")] | length'
}

wait_pool_count_at_least() {
  local expected="$1"
  local count=""
  local i
  echo "Waiting for at least $expected active pool instance(s)..."
  for i in $(seq 1 "$HEALTH_WAIT_ATTEMPTS"); do
    count="$(active_pool_count 2>/dev/null || echo 0)"
    echo "  active pool instances: $count"
    if (( count >= expected )); then
      return 0
    fi
    sleep 15
  done
  echo "ERROR: pool did not reach $expected active instance(s)." >&2
  list_pool_instances_json >&2 || true
  return 1
}

backend_count() {
  oci lb backend list \
    --load-balancer-id "$LB_ID" \
    --backend-set-name "$BACKEND_SET_NAME" \
    --all \
  | jq '.data | length'
}

print_backend_diagnostics() {
  echo "Backend set health details:" >&2
  oci lb backend-set-health get \
    --load-balancer-id "$LB_ID" \
    --backend-set-name "$BACKEND_SET_NAME" \
    --output json >&2 || true

  echo "Backends currently registered on the load balancer:" >&2
  oci lb backend list \
    --load-balancer-id "$LB_ID" \
    --backend-set-name "$BACKEND_SET_NAME" \
    --all \
    --output table >&2 || true
}

wait_backend_count_at_least() {
  local expected="$1"
  local count=""
  local i
  echo "Waiting for at least $expected registered backend(s) on the load balancer..."
  for i in $(seq 1 "$HEALTH_WAIT_ATTEMPTS"); do
    count="$(backend_count 2>/dev/null || echo 0)"
    echo "  registered backends: $count"
    if (( count >= expected )); then
      return 0
    fi
    sleep 15
  done
  echo "ERROR: load balancer did not register $expected backend(s)." >&2
  print_backend_diagnostics
  return 1
}

wait_backend_set_ok() {
  local status=""
  local i
  echo "Waiting for backend set health to become OK..."
  for i in $(seq 1 "$HEALTH_WAIT_ATTEMPTS"); do
    status=$(oci lb backend-set-health get \
      --load-balancer-id "$LB_ID" \
      --backend-set-name "$BACKEND_SET_NAME" \
      --query 'data.status' \
      --raw-output 2>/dev/null || echo UNKNOWN)
    echo "  backend set health: $status"
    if [[ "$status" == "OK" ]]; then
      return 0
    fi
    sleep 15
  done
  echo "ERROR: backend set did not reach OK. Aborting before any more VMs are removed." >&2
  print_backend_diagnostics
  return 1
}

scale_pool_to() {
  local desired="$1"
  local current=""
  local attempt
  local output=""
  local rc

  for attempt in $(seq 1 "$SCALE_UPDATE_ATTEMPTS"); do
    current="$(pool_size 2>/dev/null || echo unknown)"
    if [[ "$current" == "$desired" ]]; then
      echo "Pool already has target size $desired."
      return 0
    fi

    echo "Scaling pool target size from $current to $desired, attempt $attempt/$SCALE_UPDATE_ATTEMPTS..."
    set +e
    output=$(oci compute-management instance-pool update \
      --instance-pool-id "$INSTANCE_POOL_ID" \
      --size "$desired" \
      --wait-for-state RUNNING \
      --max-wait-seconds 1800 \
      --wait-interval-seconds 15 \
      --max-retries "$OCI_MAX_RETRIES" 2>&1)
    rc=$?
    set -e

    if (( rc == 0 )); then
      return 0
    fi

    echo "$output" >&2
    echo "Scale/update returned an error; checking pool state before retry." >&2
    wait_pool_running || true
    retry_sleep "$attempt"
  done

  echo "ERROR: failed to set pool target size to $desired." >&2
  return 1
}

instance_in_pool() {
  local instance_id="$1"
  list_pool_instances_json \
  | jq -e --arg id "$instance_id" '.data[] | select(.id == $id)' >/dev/null
}

instance_state() {
  local instance_id="$1"
  oci compute instance get \
    --instance-id "$instance_id" \
    --query 'data."lifecycle-state"' \
    --raw-output 2>/dev/null || true
}

wait_instance_terminal_or_gone() {
  local instance_id="$1"
  local state=""
  local i
  echo "Waiting for instance to terminate: $instance_id"
  for i in $(seq 1 120); do
    state="$(instance_state "$instance_id")"
    echo "  instance state: ${state:-not found}"
    case "$state" in
      ""|TERMINATED)
        return 0
        ;;
    esac
    sleep 10
  done
  echo "ERROR: instance did not reach TERMINATED: $instance_id" >&2
  return 1
}

backend_name_for_instance() {
  local instance_id="$1"
  local vnic_id=""
  local private_ip=""

  vnic_id=$(oci compute vnic-attachment list \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-id "$instance_id" \
    --all \
  | jq -r '.data[] | select(."lifecycle-state" == "ATTACHED") | ."vnic-id"' \
  | head -n 1)

  if [[ -z "$vnic_id" || "$vnic_id" == "null" ]]; then
    echo "ERROR: could not find attached VNIC for $instance_id" >&2
    return 1
  fi

  private_ip=$(oci network vnic get \
    --vnic-id "$vnic_id" \
    --query 'data."private-ip"' \
    --raw-output)

  if [[ -z "$private_ip" || "$private_ip" == "null" ]]; then
    echo "ERROR: could not find private IP for VNIC $vnic_id" >&2
    return 1
  fi

  echo "${private_ip}:${APP_PORT}"
}

backend_exists() {
  local backend_name="$1"
  [[ -z "$backend_name" ]] && return 1
  oci lb backend get \
    --load-balancer-id "$LB_ID" \
    --backend-set-name "$BACKEND_SET_NAME" \
    --backend-name "$backend_name" >/dev/null 2>&1
}

drain_backend() {
  local backend_name="$1"
  local backend_json=""
  local backup=""
  local offline=""
  local weight=""
  local max_connections=""
  local extra_args=()

  if [[ -z "$backend_name" ]]; then
    echo "No backend name was resolved; skipping drain."
    return 0
  fi

  if ! backend_exists "$backend_name"; then
    echo "Backend $backend_name is not registered on the load balancer; skipping drain."
    return 0
  fi

  backend_json=$(oci lb backend get \
    --load-balancer-id "$LB_ID" \
    --backend-set-name "$BACKEND_SET_NAME" \
    --backend-name "$backend_name")

  backup=$(jq -r '.data.backup // false' <<< "$backend_json")
  offline=$(jq -r '.data.offline // false' <<< "$backend_json")
  weight=$(jq -r '.data.weight // 1' <<< "$backend_json")
  max_connections=$(jq -r '.data."max-connections" // empty' <<< "$backend_json")

  if [[ -n "$max_connections" && "$max_connections" != "null" ]]; then
    extra_args+=(--max-connections "$max_connections")
  fi

  echo "Draining backend $backend_name..."
  oci lb backend update \
    --load-balancer-id "$LB_ID" \
    --backend-set-name "$BACKEND_SET_NAME" \
    --backend-name "$backend_name" \
    --backup "$backup" \
    --offline "$offline" \
    --weight "$weight" \
    --drain true \
    "${extra_args[@]}" \
    --wait-for-state SUCCEEDED \
    --max-wait-seconds 1200 \
    --wait-interval-seconds 10 \
    --max-retries "$OCI_MAX_RETRIES" >/dev/null
}

delete_stale_backend_if_needed() {
  local backend_name="$1"
  local i

  if [[ "$DELETE_STALE_BACKEND" != "true" ]]; then
    return 0
  fi
  if [[ -z "$backend_name" ]]; then
    return 0
  fi

  for i in $(seq 1 12); do
    if ! backend_exists "$backend_name"; then
      return 0
    fi
    sleep 10
  done

  if backend_exists "$backend_name"; then
    echo "Removing stale LB backend $backend_name..."
    oci lb backend delete \
      --load-balancer-id "$LB_ID" \
      --backend-set-name "$BACKEND_SET_NAME" \
      --backend-name "$backend_name" \
      --force \
      --wait-for-state SUCCEEDED \
      --max-retries "$OCI_MAX_RETRIES" >/dev/null || true
  fi
}

terminate_standalone_if_needed() {
  local instance_id="$1"
  local state=""
  state="$(instance_state "$instance_id")"

  case "$state" in
    ""|TERMINATED|TERMINATING)
      echo "Instance $instance_id is already ${state:-not found}."
      return 0
      ;;
    *)
      echo "Instance $instance_id is detached from pool but still $state; terminating standalone instance..."
      oci compute instance terminate \
        --instance-id "$instance_id" \
        --preserve-boot-volume false \
        --force \
        --wait-for-state TERMINATED \
        --max-wait-seconds 1800 \
        --wait-interval-seconds 15 \
        --max-retries "$OCI_MAX_RETRIES" >/dev/null
      return 0
      ;;
  esac
}

safe_detach_terminate_decrement() {
  local instance_id="$1"
  local attempt
  local rc
  local output=""

  for attempt in $(seq 1 "$DETACH_ATTEMPTS"); do
    if ! instance_in_pool "$instance_id"; then
      echo "Instance $instance_id is no longer attached to the pool. Checking compute state..."
      terminate_standalone_if_needed "$instance_id"
      return 0
    fi

    echo "Detach attempt $attempt/$DETACH_ATTEMPTS for $instance_id..."
    set +e
    output=$(oci compute-management instance-pool-instance detach \
      --instance-pool-id "$INSTANCE_POOL_ID" \
      --instance-id "$instance_id" \
      --is-auto-terminate true \
      --is-decrement-size true \
      --wait-for-state SUCCEEDED \
      --max-wait-seconds 1800 \
      --wait-interval-seconds 15 \
      --max-retries "$OCI_MAX_RETRIES" 2>&1)
    rc=$?
    set -e

    if (( rc == 0 )); then
      echo "Detach succeeded for $instance_id."
      if instance_in_pool "$instance_id"; then
        echo "WARNING: detach returned success but the instance still appears in the pool; waiting for convergence." >&2
        sleep 20
        if instance_in_pool "$instance_id"; then
          echo "ERROR: instance still appears attached after successful detach response." >&2
          return 1
        fi
      fi
      terminate_standalone_if_needed "$instance_id"
      return 0
    fi

    echo "$output" >&2
    echo "Detach returned an error. Checking whether OCI partially completed the operation..." >&2

    if ! instance_in_pool "$instance_id"; then
      echo "Instance $instance_id is no longer in the pool after the failed response."
      terminate_standalone_if_needed "$instance_id"
      return 0
    fi

    if (( attempt < DETACH_ATTEMPTS )); then
      retry_sleep "$attempt"
    fi
  done

  echo "ERROR: detach kept failing for $instance_id." >&2
  echo "The script is stopping with the pool still surged and the old backend drained to avoid downtime." >&2
  echo "Retry later or use REPLACEMENT_METHOD=terminate to avoid the detach API path." >&2
  return 1
}

safe_terminate_pool_member_and_restore_size() {
  local instance_id="$1"
  local steady_size="$2"
  local attempt
  local state=""
  local rc
  local output=""

  for attempt in $(seq 1 "$TERMINATE_ATTEMPTS"); do
    state="$(instance_state "$instance_id")"
    case "$state" in
      ""|TERMINATED|TERMINATING)
        echo "Instance $instance_id is already ${state:-not found}."
        break
        ;;
    esac

    echo "Terminating pool member directly, attempt $attempt/$TERMINATE_ATTEMPTS: $instance_id"
    set +e
    output=$(oci compute instance terminate \
      --instance-id "$instance_id" \
      --preserve-boot-volume false \
      --force \
      --max-retries "$OCI_MAX_RETRIES" 2>&1)
    rc=$?
    set -e

    if (( rc == 0 )); then
      echo "Terminate request accepted for $instance_id."
      break
    fi

    echo "$output" >&2
    state="$(instance_state "$instance_id")"
    if [[ "$state" == "TERMINATING" || "$state" == "TERMINATED" || -z "$state" ]]; then
      echo "Terminate appears to have been accepted despite the CLI error; state is ${state:-not found}."
      break
    fi

    if (( attempt < TERMINATE_ATTEMPTS )); then
      retry_sleep "$attempt"
    else
      echo "ERROR: instance terminate kept failing for $instance_id." >&2
      echo "The script is stopping with the pool still surged and the backend drained." >&2
      return 1
    fi
  done

  # Important: direct termination of a pool member can cause the pool to launch a
  # replacement to maintain the current target size. Because we already surged to
  # steady_size + SURGE_BY, immediately return the pool target to steady_size.
  echo "Restoring pool target size to steady size $steady_size after direct termination request..."
  scale_pool_to "$steady_size"

  wait_instance_terminal_or_gone "$instance_id" || true
  return 0
}

prepare_rollout_state() {
  if [[ "${RESET_ROLLOUT_STATE:-false}" == "true" ]]; then
    echo "Resetting rollout state directory: $ROLLOUT_STATE_DIR"
    rm -rf "$ROLLOUT_STATE_DIR"
  fi

  mkdir -p "$ROLLOUT_STATE_DIR"
  touch "$DONE_IDS_FILE"

  if [[ -f "$CONFIG_ID_FILE" ]]; then
    local previous_config
    previous_config="$(cat "$CONFIG_ID_FILE")"
    if [[ "$previous_config" != "$NEW_INSTANCE_CONFIG_ID" ]]; then
      echo "ERROR: rollout state was created for a different instance configuration." >&2
      echo "  state config: $previous_config" >&2
      echo "  requested:     $NEW_INSTANCE_CONFIG_ID" >&2
      echo "Set RESET_ROLLOUT_STATE=true if you intentionally want to start a new rollout." >&2
      exit 1
    fi
  else
    printf '%s\n' "$NEW_INSTANCE_CONFIG_ID" > "$CONFIG_ID_FILE"
  fi

  if [[ ! -f "$STEADY_SIZE_FILE" ]]; then
    local steady_size
    steady_size="${TARGET_POOL_SIZE:-$(pool_size)}"
    printf '%s\n' "$steady_size" > "$STEADY_SIZE_FILE"
  fi

  if [[ ! -f "$OLD_IDS_FILE" ]]; then
    echo "Capturing current pool members as old instances to replace..."
    list_active_pool_instance_ids > "$OLD_IDS_FILE"
    if [[ ! -s "$OLD_IDS_FILE" ]]; then
      echo "ERROR: no active instances found in pool $INSTANCE_POOL_ID" >&2
      exit 1
    fi
  fi
}

mark_done() {
  local instance_id="$1"
  if ! grep -Fxq "$instance_id" "$DONE_IDS_FILE"; then
    printf '%s\n' "$instance_id" >> "$DONE_IDS_FILE"
  fi
}

is_done() {
  local instance_id="$1"
  grep -Fxq "$instance_id" "$DONE_IDS_FILE"
}

main() {
  local original_size=""
  local surge_size=""
  local old_instance_id=""
  local old_backend_name=""
  local final_size=""

  validate_new_instance_config
  prepare_rollout_state

  original_size="$(cat "$STEADY_SIZE_FILE")"
  surge_size=$((original_size + SURGE_BY))

  echo "Original target pool size: $original_size"
  echo "Surge target pool size:    $surge_size"
  echo "Replacement method:        $REPLACEMENT_METHOD"
  echo "Rollout state dir:         $ROLLOUT_STATE_DIR"
  echo "New instance config:       $NEW_INSTANCE_CONFIG_ID"
  echo "Instances to replace:"
  sed 's/^/  /' "$OLD_IDS_FILE"

  echo "Checking current backend health before rollout..."
  wait_backend_set_ok

  echo "Updating pool to the new instance configuration..."
  oci compute-management instance-pool update \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --instance-configuration-id "$NEW_INSTANCE_CONFIG_ID" \
    --wait-for-state RUNNING \
    --max-wait-seconds 1800 \
    --wait-interval-seconds 15 \
    --max-retries "$OCI_MAX_RETRIES" >/dev/null
  wait_pool_running

  while IFS= read -r old_instance_id; do
    [[ -z "$old_instance_id" ]] && continue

    echo
    if is_done "$old_instance_id"; then
      echo "Skipping already completed instance: $old_instance_id"
      continue
    fi

    echo "Replacing old instance: $old_instance_id"

    old_backend_name=""
    if instance_in_pool "$old_instance_id"; then
      old_backend_name="$(backend_name_for_instance "$old_instance_id" || true)"
    else
      echo "Instance $old_instance_id is no longer in the pool; cleaning up if needed."
      old_backend_name="$(backend_name_for_instance "$old_instance_id" 2>/dev/null || true)"
      terminate_standalone_if_needed "$old_instance_id"
      delete_stale_backend_if_needed "$old_backend_name"
      mark_done "$old_instance_id"
      continue
    fi

    scale_pool_to "$surge_size"
    wait_pool_count_at_least "$surge_size"
    wait_backend_count_at_least "$surge_size"
    wait_backend_set_ok

    drain_backend "$old_backend_name"
    echo "Waiting ${DRAIN_SECONDS}s for existing connections to drain..."
    sleep "$DRAIN_SECONDS"

    if [[ "$REPLACEMENT_METHOD" == "terminate" ]]; then
      safe_terminate_pool_member_and_restore_size "$old_instance_id" "$original_size"
    else
      safe_detach_terminate_decrement "$old_instance_id"
    fi

    delete_stale_backend_if_needed "$old_backend_name"
    wait_pool_running
    wait_pool_count_at_least "$original_size"
    wait_backend_count_at_least "$original_size"
    wait_backend_set_ok

    mark_done "$old_instance_id"
    echo "Completed replacement for $old_instance_id"
  done < "$OLD_IDS_FILE"

  final_size="$(pool_size)"
  if [[ "$final_size" != "$original_size" ]]; then
    echo "Final pool target size is $final_size; resetting to $original_size..."
    scale_pool_to "$original_size"
    wait_pool_running
    wait_pool_count_at_least "$original_size"
    wait_backend_set_ok
  fi

  echo
  echo "Rolling replacement completed successfully."
  if [[ -n "${LB_IP:-}" && -n "${LISTENER_PORT:-}" ]]; then
    echo "Sample through the load balancer:"
    echo "  curl -s http://$LB_IP:$LISTENER_PORT/ | jq ."
  fi
}

main "$@"
