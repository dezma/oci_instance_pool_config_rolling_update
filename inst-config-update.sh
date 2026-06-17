#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v4"

# Safe rolling instance-pool replacement for OCI Compute instance pools behind OCI Load Balancer.
# Key safeguards:
# - Captures only real, active pool instances that still exist in Compute and have an attached VNIC.
# - Defaults to instance-pool detach with --is-auto-terminate true and --is-decrement-size true.
# - Can auto-discover all load balancer attachments from the instance pool and drain/delete old
#   backends from every attached backend set/port.
# - Can clean stale LB backends that no longer map to active pool instances.
# - Avoids continuing when it cannot prove replacement capacity and LB health are OK.

usage() {
  cat <<'USAGE'
Usage:
  inst-config-update.sh [options]

Required for rollout:
  --new-instance-config-id <ocid>    New instance configuration OCID to apply to the pool.
  --compartment-id <ocid>            Compartment OCID used to list pool instances and VNIC attachments.
  --instance-pool-id <ocid>          Instance pool OCID.

Load balancer selection:
  --all-attached-backends            Use all ATTACHED load balancer attachments found on the pool.
                                     Recommended when the pool is attached to multiple backend sets.
  --lb-id <ocid>                     Restrict to this load balancer. Required when using a single backend.
  --backend-set-name <name>          Single backend set name. Used with --app-port.
  --app-port <port>                  Single backend port. Used with --backend-set-name.

Optional:
  --surge-by <n>                     Extra pool capacity during replacement. Default: 1.
  --drain-seconds <seconds>          Drain wait after marking old backends drained. Default: 120.
  --replacement-method <mode>        detach or terminate. Default: detach.
                                     detach is recommended. terminate is kept only as a workaround.
  --delete-stale-backend <true|false>
                                     Delete old backend entries after drain. Default: true.
  --cleanup-stale-backends-only      Do not roll. Remove LB backends that are not active pool members.
                                     Assumes selected backend sets are dedicated to this instance pool.
  --pre-clean-stale-backends <true|false>
                                     Cleanup orphaned backends before rollout. Default: false.
  --post-clean-stale-backends <true|false>
                                     Cleanup orphaned backends after rollout. Default: false.
  --reset-rollout-state              Start fresh and recapture active pool members.
  --rollout-state-dir <path>         State directory. Default: ./rolling-replace-state.
  --env-file <path>                  Optional env file to source before validation.
  --no-env-file                      Ignore env files. This is the default behavior.
  --health-wait-attempts <n>         Poll attempts for health/count waits. Default: 80.
  --oci-max-retries <n>              OCI CLI max retries. Default: 8.
  -h, --help                         Show this help.

Examples:
  # Recommended for a pool with multiple LB backend-set attachments:
  ./inst-config-update.sh \
    --no-env-file \
    --new-instance-config-id ocid1.instanceconfiguration.oc1..example \
    --compartment-id ocid1.compartment.oc1..example \
    --instance-pool-id ocid1.instancepool.oc1..example \
    --all-attached-backends \
    --surge-by 1 \
    --drain-seconds 120 \
    --replacement-method detach \
    --reset-rollout-state

  # Cleanup stale backends across every backend set attached to the pool:
  ./inst-config-update.sh \
    --cleanup-stale-backends-only \
    --compartment-id ocid1.compartment.oc1..example \
    --instance-pool-id ocid1.instancepool.oc1..example \
    --all-attached-backends

  # Single backend-set mode, compatible with older script usage:
  ./inst-config-update.sh \
    --new-instance-config-id ocid1.instanceconfiguration.oc1..example \
    --compartment-id ocid1.compartment.oc1..example \
    --instance-pool-id ocid1.instancepool.oc1..example \
    --lb-id ocid1.loadbalancer.oc1..example \
    --backend-set-name my-backend-set \
    --app-port 8080
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

# Defaults
NO_ENV_FILE=true
ALL_ATTACHED_BACKENDS=false
CLEANUP_STALE_BACKENDS_ONLY=false
RESET_ROLLOUT_STATE=false
SURGE_BY=1
DRAIN_SECONDS=120
REPLACEMENT_METHOD="detach"
DELETE_STALE_BACKEND="true"
PRE_CLEAN_STALE_BACKENDS="false"
POST_CLEAN_STALE_BACKENDS="false"
HEALTH_WAIT_ATTEMPTS=80
OCI_MAX_RETRIES=8
ROLLOUT_STATE_DIR="./rolling-replace-state"

# Optional env-backed variables
NEW_INSTANCE_CONFIG_ID="${NEW_INSTANCE_CONFIG_ID:-}"
COMPARTMENT_ID="${COMPARTMENT_ID:-}"
INSTANCE_POOL_ID="${INSTANCE_POOL_ID:-}"
LB_ID="${LB_ID:-}"
BACKEND_SET_NAME="${BACKEND_SET_NAME:-}"
APP_PORT="${APP_PORT:-}"
ENV_FILE="${ENV_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --new-instance-config-id) NEW_INSTANCE_CONFIG_ID="$2"; shift 2 ;;
    --new-instance-config-id=*) NEW_INSTANCE_CONFIG_ID="${1#*=}"; shift ;;
    --compartment-id) COMPARTMENT_ID="$2"; shift 2 ;;
    --compartment-id=*) COMPARTMENT_ID="${1#*=}"; shift ;;
    --instance-pool-id) INSTANCE_POOL_ID="$2"; shift 2 ;;
    --instance-pool-id=*) INSTANCE_POOL_ID="${1#*=}"; shift ;;
    --lb-id) LB_ID="$2"; shift 2 ;;
    --lb-id=*) LB_ID="${1#*=}"; shift ;;
    --backend-set-name) BACKEND_SET_NAME="$2"; shift 2 ;;
    --backend-set-name=*) BACKEND_SET_NAME="${1#*=}"; shift ;;
    --app-port) APP_PORT="$2"; shift 2 ;;
    --app-port=*) APP_PORT="${1#*=}"; shift ;;
    --all-attached-backends) ALL_ATTACHED_BACKENDS=true; shift ;;
    --surge-by) SURGE_BY="$2"; shift 2 ;;
    --surge-by=*) SURGE_BY="${1#*=}"; shift ;;
    --drain-seconds) DRAIN_SECONDS="$2"; shift 2 ;;
    --drain-seconds=*) DRAIN_SECONDS="${1#*=}"; shift ;;
    --replacement-method) REPLACEMENT_METHOD="$2"; shift 2 ;;
    --replacement-method=*) REPLACEMENT_METHOD="${1#*=}"; shift ;;
    --delete-stale-backend) DELETE_STALE_BACKEND="$2"; shift 2 ;;
    --delete-stale-backend=*) DELETE_STALE_BACKEND="${1#*=}"; shift ;;
    --cleanup-stale-backends-only) CLEANUP_STALE_BACKENDS_ONLY=true; shift ;;
    --pre-clean-stale-backends) PRE_CLEAN_STALE_BACKENDS="$2"; shift 2 ;;
    --pre-clean-stale-backends=*) PRE_CLEAN_STALE_BACKENDS="${1#*=}"; shift ;;
    --post-clean-stale-backends) POST_CLEAN_STALE_BACKENDS="$2"; shift 2 ;;
    --post-clean-stale-backends=*) POST_CLEAN_STALE_BACKENDS="${1#*=}"; shift ;;
    --reset-rollout-state) RESET_ROLLOUT_STATE=true; shift ;;
    --rollout-state-dir) ROLLOUT_STATE_DIR="$2"; shift 2 ;;
    --rollout-state-dir=*) ROLLOUT_STATE_DIR="${1#*=}"; shift ;;
    --env-file) ENV_FILE="$2"; NO_ENV_FILE=false; shift 2 ;;
    --env-file=*) ENV_FILE="${1#*=}"; NO_ENV_FILE=false; shift ;;
    --no-env-file) NO_ENV_FILE=true; ENV_FILE=""; shift ;;
    --health-wait-attempts) HEALTH_WAIT_ATTEMPTS="$2"; shift 2 ;;
    --health-wait-attempts=*) HEALTH_WAIT_ATTEMPTS="${1#*=}"; shift ;;
    --oci-max-retries) OCI_MAX_RETRIES="$2"; shift 2 ;;
    --oci-max-retries=*) OCI_MAX_RETRIES="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ "$NO_ENV_FILE" != "true" ]]; then
  if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
    err "--env-file was specified but the file does not exist: ${ENV_FILE:-<empty>}"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

require_cmd oci
require_cmd jq
require_cmd sort
require_cmd mktemp

[[ -n "$COMPARTMENT_ID" ]] || { err "missing --compartment-id"; exit 1; }
[[ -n "$INSTANCE_POOL_ID" ]] || { err "missing --instance-pool-id"; exit 1; }
if [[ "$CLEANUP_STALE_BACKENDS_ONLY" != "true" ]]; then
  [[ -n "$NEW_INSTANCE_CONFIG_ID" ]] || { err "missing --new-instance-config-id"; exit 1; }
fi
case "$REPLACEMENT_METHOD" in
  detach|terminate) ;;
  *) err "--replacement-method must be detach or terminate"; exit 1 ;;
esac
case "$DELETE_STALE_BACKEND" in
  true|false) ;;
  *) err "--delete-stale-backend must be true or false"; exit 1 ;;
esac
case "$PRE_CLEAN_STALE_BACKENDS" in
  true|false) ;;
  *) err "--pre-clean-stale-backends must be true or false"; exit 1 ;;
esac
case "$POST_CLEAN_STALE_BACKENDS" in
  true|false) ;;
  *) err "--post-clean-stale-backends must be true or false"; exit 1 ;;
esac
[[ "$SURGE_BY" =~ ^[0-9]+$ ]] || { err "--surge-by must be a non-negative integer"; exit 1; }
(( SURGE_BY >= 1 || CLEANUP_STALE_BACKENDS_ONLY == true )) || { err "--surge-by must be at least 1 for rollout"; exit 1; }
[[ "$DRAIN_SECONDS" =~ ^[0-9]+$ ]] || { err "--drain-seconds must be a non-negative integer"; exit 1; }

STATE_DIR="$ROLLOUT_STATE_DIR"
ATTACHMENTS_FILE="$STATE_DIR/lb-attachments.tsv"
OLD_IDS_FILE="$STATE_DIR/old-instance-ids.txt"
DONE_IDS_FILE="$STATE_DIR/done-instance-ids.txt"
STEADY_SIZE_FILE="$STATE_DIR/original-size.txt"
IP_CACHE_DIR="$STATE_DIR/instance-private-ips"
WARNINGS_FILE="$STATE_DIR/warnings.txt"

mkdir -p "$STATE_DIR" "$IP_CACHE_DIR"
touch "$DONE_IDS_FILE" "$WARNINGS_FILE"

pool_get_json() {
  oci compute-management instance-pool get --instance-pool-id "$INSTANCE_POOL_ID"
}

pool_size() {
  pool_get_json | jq -r '.data.size'
}

pool_state() {
  pool_get_json | jq -r '.data."lifecycle-state"'
}

list_pool_instances_json() {
  oci compute-management instance-pool list-instances \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --all
}

instance_state() {
  local instance_id="$1"
  oci compute instance get \
    --instance-id "$instance_id" \
    --query 'data."lifecycle-state"' \
    --raw-output 2>/dev/null || true
}

instance_in_pool() {
  local instance_id="$1"
  list_pool_instances_json | jq -e --arg id "$instance_id" '.data[] | select(.id == $id)' >/dev/null
}

private_ip_cache_file() {
  local instance_id="$1"
  printf '%s/%s.ip\n' "$IP_CACHE_DIR" "$(printf '%s' "$instance_id" | tr -c 'A-Za-z0-9_.-' '_')"
}

private_ip_for_instance() {
  local instance_id="$1"
  local cache_file=""
  local vnic_id=""
  local private_ip=""
  cache_file="$(private_ip_cache_file "$instance_id")"

  if [[ -s "$cache_file" ]]; then
    head -n 1 "$cache_file"
    return 0
  fi

  vnic_id=$(oci compute vnic-attachment list \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-id "$instance_id" \
    --all \
  | jq -r '.data[] | select(."lifecycle-state" == "ATTACHED") | ."vnic-id"' \
  | head -n 1)

  if [[ -z "$vnic_id" || "$vnic_id" == "null" ]]; then
    return 1
  fi

  private_ip=$(oci network vnic get \
    --vnic-id "$vnic_id" \
    --query 'data."private-ip"' \
    --raw-output 2>/dev/null || true)

  if [[ -z "$private_ip" || "$private_ip" == "null" ]]; then
    return 1
  fi

  printf '%s\n' "$private_ip" > "$cache_file"
  printf '%s\n' "$private_ip"
}

is_valid_active_instance() {
  local instance_id="$1"
  local cstate=""
  cstate="$(instance_state "$instance_id")"
  case "$cstate" in
    RUNNING|STARTING|PROVISIONING)
      ;;
    *)
      warn "skipping stale/non-active pool member $instance_id; compute state is ${cstate:-not found}"
      printf 'skipped_non_active %s state=%s\n' "$instance_id" "${cstate:-not_found}" >> "$WARNINGS_FILE"
      return 1
      ;;
  esac

  if ! private_ip_for_instance "$instance_id" >/dev/null 2>&1; then
    warn "skipping pool member $instance_id because no attached VNIC/private IP could be resolved"
    printf 'skipped_no_vnic %s\n' "$instance_id" >> "$WARNINGS_FILE"
    return 1
  fi

  return 0
}

list_valid_active_pool_instance_ids() {
  local id=""
  list_pool_instances_json \
  | jq -r '.data[] | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING") | .id' \
  | while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      if is_valid_active_instance "$id"; then
        printf '%s\n' "$id"
      fi
    done
}

valid_active_pool_count() {
  list_valid_active_pool_instance_ids | wc -l | tr -d ' '
}

load_lb_attachments() {
  local pool_json=""
  local count=""

  mkdir -p "$STATE_DIR"
  : > "$ATTACHMENTS_FILE"

  if [[ "$ALL_ATTACHED_BACKENDS" == "true" ]]; then
    pool_json="$(pool_get_json)"
    jq -r --arg lb_filter "$LB_ID" '
      .data."load-balancers"[]?
      | select(."lifecycle-state" == "ATTACHED")
      | select(($lb_filter == "") or (."load-balancer-id" == $lb_filter))
      | [."load-balancer-id", ."backend-set-name", (.port|tostring)]
      | @tsv
    ' <<< "$pool_json" > "$ATTACHMENTS_FILE"
  else
    [[ -n "$LB_ID" ]] || { err "missing --lb-id. Use --all-attached-backends to auto-discover pool attachments."; exit 1; }
    [[ -n "$BACKEND_SET_NAME" ]] || { err "missing --backend-set-name, or use --all-attached-backends."; exit 1; }
    [[ -n "$APP_PORT" ]] || { err "missing --app-port, or use --all-attached-backends."; exit 1; }
    printf '%s\t%s\t%s\n' "$LB_ID" "$BACKEND_SET_NAME" "$APP_PORT" > "$ATTACHMENTS_FILE"
  fi

  count=$(wc -l < "$ATTACHMENTS_FILE" | tr -d ' ')
  if [[ "$count" == "0" ]]; then
    err "no load balancer attachments selected. Check --all-attached-backends, --lb-id, and pool attachments."
    exit 1
  fi

  log "Selected load balancer backend attachments:"
  awk -F '\t' '{printf "  lb=%s backend_set=%s port=%s\n", $1, $2, $3}' "$ATTACHMENTS_FILE"
}

backend_name_for_ip_port() {
  local ip="$1"
  local port="$2"
  printf '%s:%s\n' "$ip" "$port"
}

backend_exists() {
  local lb_id="$1"
  local backend_set="$2"
  local backend_name="$3"
  oci lb backend get \
    --load-balancer-id "$lb_id" \
    --backend-set-name "$backend_set" \
    --backend-name "$backend_name" >/dev/null 2>&1
}

backend_count_for_attachment() {
  local lb_id="$1"
  local backend_set="$2"
  local port="$3"
  oci lb backend list \
    --load-balancer-id "$lb_id" \
    --backend-set-name "$backend_set" \
    --all \
  | jq --argjson port "$port" '[.data[] | select(.port == $port)] | length'
}

backend_set_status() {
  local lb_id="$1"
  local backend_set="$2"
  oci lb backend-set-health get \
    --load-balancer-id "$lb_id" \
    --backend-set-name "$backend_set" \
    --query 'data.status' \
    --raw-output 2>/dev/null || echo UNKNOWN
}

print_backend_diagnostics() {
  local lb_id=""
  local backend_set=""
  local port=""
  while IFS=$'\t' read -r lb_id backend_set port; do
    [[ -z "$lb_id" ]] && continue
    echo "Diagnostics for backend set $backend_set port $port" >&2
    oci lb backend-set-health get \
      --load-balancer-id "$lb_id" \
      --backend-set-name "$backend_set" \
      --output json >&2 || true
    oci lb backend list \
      --load-balancer-id "$lb_id" \
      --backend-set-name "$backend_set" \
      --all \
      --output table >&2 || true
  done < "$ATTACHMENTS_FILE"
}

wait_all_backend_sets_ok() {
  local i=""
  local lb_id=""
  local backend_set=""
  local port=""
  local status=""
  local all_ok=""

  log "Waiting for selected backend set health to become OK..."
  for i in $(seq 1 "$HEALTH_WAIT_ATTEMPTS"); do
    all_ok=true
    while IFS=$'\t' read -r lb_id backend_set port; do
      [[ -z "$lb_id" ]] && continue
      status="$(backend_set_status "$lb_id" "$backend_set")"
      log "  $backend_set:$port health: $status"
      if [[ "$status" != "OK" ]]; then
        all_ok=false
      fi
    done < "$ATTACHMENTS_FILE"
    if [[ "$all_ok" == "true" ]]; then
      return 0
    fi
    sleep 15
  done

  err "one or more selected backend sets did not reach OK"
  print_backend_diagnostics
  return 1
}

wait_backend_counts_at_least() {
  local expected="$1"
  local i=""
  local lb_id=""
  local backend_set=""
  local port=""
  local count=""
  local all_good=""

  log "Waiting for at least $expected backend(s) in each selected backend set..."
  for i in $(seq 1 "$HEALTH_WAIT_ATTEMPTS"); do
    all_good=true
    while IFS=$'\t' read -r lb_id backend_set port; do
      [[ -z "$lb_id" ]] && continue
      count="$(backend_count_for_attachment "$lb_id" "$backend_set" "$port" 2>/dev/null || echo 0)"
      log "  $backend_set:$port registered backends: $count"
      if (( count < expected )); then
        all_good=false
      fi
    done < "$ATTACHMENTS_FILE"
    if [[ "$all_good" == "true" ]]; then
      return 0
    fi
    sleep 15
  done

  err "one or more selected backend sets did not register $expected backend(s)"
  print_backend_diagnostics
  return 1
}

wait_valid_pool_count_at_least() {
  local expected="$1"
  local i=""
  local count=""
  log "Waiting for at least $expected valid active pool instance(s)..."
  for i in $(seq 1 "$HEALTH_WAIT_ATTEMPTS"); do
    count="$(valid_active_pool_count 2>/dev/null || echo 0)"
    log "  valid active pool instances: $count"
    if (( count >= expected )); then
      return 0
    fi
    sleep 15
  done
  err "pool did not reach $expected valid active instance(s)"
  list_pool_instances_json >&2 || true
  return 1
}

wait_pool_running() {
  local i=""
  local state=""
  log "Waiting for instance pool to be RUNNING..."
  for i in $(seq 1 120); do
    state="$(pool_state 2>/dev/null || echo UNKNOWN)"
    log "  pool state: $state"
    if [[ "$state" == "RUNNING" ]]; then
      return 0
    fi
    sleep 10
  done
  err "instance pool did not return to RUNNING"
  return 1
}

scale_pool_to() {
  local desired="$1"
  local current=""
  local attempt=""
  for attempt in $(seq 1 8); do
    current="$(pool_size 2>/dev/null || echo unknown)"
    if [[ "$current" == "$desired" ]]; then
      log "Pool already has target size $desired."
      return 0
    fi
    log "Scaling pool target size from $current to $desired, attempt $attempt/8..."
    if oci compute-management instance-pool update \
      --instance-pool-id "$INSTANCE_POOL_ID" \
      --size "$desired" \
      --wait-for-state RUNNING \
      --max-wait-seconds 1800 \
      --wait-interval-seconds 15 \
      --max-retries "$OCI_MAX_RETRIES" >/dev/null; then
      return 0
    fi
    warn "scale/update failed; checking pool state before retry"
    wait_pool_running || true
    sleep $((attempt * 20))
  done
  err "failed to set pool target size to $desired"
  return 1
}

drain_backend_if_exists() {
  local lb_id="$1"
  local backend_set="$2"
  local backend_name="$3"
  local backend_json=""
  local backup=""
  local offline=""
  local weight=""
  local max_connections=""
  local extra_args=()

  if ! backend_exists "$lb_id" "$backend_set" "$backend_name"; then
    log "Backend $backend_name is not registered in $backend_set; skipping drain."
    return 0
  fi

  backend_json=$(oci lb backend get \
    --load-balancer-id "$lb_id" \
    --backend-set-name "$backend_set" \
    --backend-name "$backend_name")
  backup=$(jq -r '.data.backup // false' <<< "$backend_json")
  offline=$(jq -r '.data.offline // false' <<< "$backend_json")
  weight=$(jq -r '.data.weight // 1' <<< "$backend_json")
  max_connections=$(jq -r '.data."max-connections" // empty' <<< "$backend_json")
  if [[ -n "$max_connections" && "$max_connections" != "null" ]]; then
    extra_args+=(--max-connections "$max_connections")
  fi

  log "Draining backend $backend_name in $backend_set..."
  oci lb backend update \
    --load-balancer-id "$lb_id" \
    --backend-set-name "$backend_set" \
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

delete_backend_if_exists() {
  local lb_id="$1"
  local backend_set="$2"
  local backend_name="$3"
  if [[ "$DELETE_STALE_BACKEND" != "true" ]]; then
    return 0
  fi
  if ! backend_exists "$lb_id" "$backend_set" "$backend_name"; then
    log "Backend $backend_name is already absent from $backend_set."
    return 0
  fi
  log "Deleting backend $backend_name from $backend_set..."
  oci lb backend delete \
    --load-balancer-id "$lb_id" \
    --backend-set-name "$backend_set" \
    --backend-name "$backend_name" \
    --force \
    --wait-for-state SUCCEEDED \
    --max-wait-seconds 1200 \
    --wait-interval-seconds 10 \
    --max-retries "$OCI_MAX_RETRIES" >/dev/null
}

cleanup_orphaned_lb_backends() {
  local active_ips_file=""
  local keep_file=""
  local all_file=""
  local id=""
  local ip=""
  local lb_id=""
  local backend_set=""
  local port=""
  local backend_name=""
  local deleted=0
  local kept=0
  local skipped=0

  active_ips_file="$(mktemp)"
  keep_file="$(mktemp)"
  all_file="$(mktemp)"

  log "Building active private-IP list from valid active pool instances..."
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    ip="$(private_ip_for_instance "$id" 2>/dev/null || true)"
    [[ -n "$ip" ]] && printf '%s\n' "$ip"
  done < <(list_valid_active_pool_instance_ids) | sort -u > "$active_ips_file"

  if [[ ! -s "$active_ips_file" ]]; then
    rm -f "$active_ips_file" "$keep_file" "$all_file"
    err "no valid active pool instance private IPs could be resolved; refusing to prune LB backends"
    return 1
  fi

  log "Active pool private IPs:"
  sed 's/^/  /' "$active_ips_file"

  while IFS=$'\t' read -r lb_id backend_set port; do
    [[ -z "$lb_id" ]] && continue
    : > "$keep_file"
    while IFS= read -r ip; do
      backend_name_for_ip_port "$ip" "$port"
    done < "$active_ips_file" | sort -u > "$keep_file"

    oci lb backend list \
      --load-balancer-id "$lb_id" \
      --backend-set-name "$backend_set" \
      --all \
    | jq -r --argjson port "$port" '.data[] | select(.port == $port) | .name' \
    | sort -u > "$all_file"

    log "Checking $backend_set on port $port for stale/orphaned backends..."
    while IFS= read -r backend_name; do
      [[ -z "$backend_name" ]] && continue
      if grep -Fxq "$backend_name" "$keep_file"; then
        log "Keeping active backend: $backend_set $backend_name"
        kept=$((kept + 1))
      else
        log "Pruning stale/orphaned backend: $backend_set $backend_name"
        delete_backend_if_exists "$lb_id" "$backend_set" "$backend_name"
        deleted=$((deleted + 1))
      fi
    done < "$all_file"
  done < "$ATTACHMENTS_FILE"

  rm -f "$active_ips_file" "$keep_file" "$all_file"
  log "Stale backend cleanup complete. kept=$kept deleted=$deleted skipped=$skipped"
}

validate_new_instance_config() {
  log "Validating new instance configuration exists..."
  oci compute-management instance-configuration get \
    --instance-configuration-id "$NEW_INSTANCE_CONFIG_ID" >/dev/null
}

prepare_rollout_state() {
  if [[ "$RESET_ROLLOUT_STATE" == "true" ]]; then
    log "Resetting rollout state directory: $STATE_DIR"
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR" "$IP_CACHE_DIR"
    : > "$DONE_IDS_FILE"
    : > "$WARNINGS_FILE"
  else
    mkdir -p "$STATE_DIR" "$IP_CACHE_DIR"
    touch "$DONE_IDS_FILE" "$WARNINGS_FILE"
  fi

  if [[ ! -f "$STEADY_SIZE_FILE" ]]; then
    pool_size > "$STEADY_SIZE_FILE"
  fi

  if [[ ! -f "$OLD_IDS_FILE" ]]; then
    log "Capturing valid active pool members as old instances to replace..."
    list_valid_active_pool_instance_ids | sort -u > "$OLD_IDS_FILE"
    if [[ ! -s "$OLD_IDS_FILE" ]]; then
      err "no valid active instances found in pool $INSTANCE_POOL_ID"
      exit 1
    fi
  fi
}

mark_done() {
  local instance_id="$1"
  grep -Fxq "$instance_id" "$DONE_IDS_FILE" 2>/dev/null || printf '%s\n' "$instance_id" >> "$DONE_IDS_FILE"
}

is_done() {
  local instance_id="$1"
  grep -Fxq "$instance_id" "$DONE_IDS_FILE" 2>/dev/null
}

wait_instance_terminal_or_gone() {
  local instance_id="$1"
  local state=""
  local i=""
  log "Waiting for instance to terminate: $instance_id"
  for i in $(seq 1 120); do
    state="$(instance_state "$instance_id")"
    log "  instance state: ${state:-not found}"
    case "$state" in
      ""|TERMINATED)
        return 0
        ;;
    esac
    sleep 10
  done
  err "instance did not reach TERMINATED: $instance_id"
  return 1
}

terminate_standalone_if_needed() {
  local instance_id="$1"
  local state=""
  state="$(instance_state "$instance_id")"
  case "$state" in
    ""|TERMINATED|TERMINATING)
      log "Instance $instance_id is already ${state:-not found}."
      return 0
      ;;
    RUNNING|STOPPED|STOPPING|STARTING|PROVISIONING)
      log "Instance $instance_id is detached from pool but still $state; terminating standalone instance..."
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
    *)
      warn "Instance $instance_id has unexpected compute state $state; not terminating automatically."
      return 0
      ;;
  esac
}

safe_detach_terminate_decrement() {
  local instance_id="$1"
  local attempt=""
  local output=""
  local rc=""

  for attempt in $(seq 1 5); do
    if ! instance_in_pool "$instance_id"; then
      log "Instance $instance_id is already not in the pool."
      terminate_standalone_if_needed "$instance_id"
      return 0
    fi

    log "Detaching and auto-terminating pool member, attempt $attempt/5: $instance_id"
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
      if instance_in_pool "$instance_id"; then
        warn "detach returned success but instance still appears in the pool; waiting for convergence"
        sleep 60
        if instance_in_pool "$instance_id"; then
          err "instance still appears attached after successful detach response"
          return 1
        fi
      fi
      terminate_standalone_if_needed "$instance_id"
      return 0
    fi

    echo "$output" >&2
    warn "detach returned an error; checking actual state before retry"
    if ! instance_in_pool "$instance_id"; then
      terminate_standalone_if_needed "$instance_id"
      return 0
    fi
    sleep $((attempt * 30))
  done

  err "detach kept failing for $instance_id. Leaving rollout stopped with replacement capacity in place."
  return 1
}

safe_direct_terminate_and_restore_size() {
  local instance_id="$1"
  local original_size="$2"
  warn "Using direct terminate mode. This can leave stale pool membership in OCI; detach mode is recommended."
  oci compute instance terminate \
    --instance-id "$instance_id" \
    --preserve-boot-volume false \
    --force \
    --max-retries "$OCI_MAX_RETRIES" >/dev/null || true
  scale_pool_to "$original_size"
  wait_instance_terminal_or_gone "$instance_id"
}

drain_old_backends_for_ip() {
  local old_ip="$1"
  local lb_id=""
  local backend_set=""
  local port=""
  local backend_name=""

  while IFS=$'	' read -r lb_id backend_set port; do
    [[ -z "$lb_id" ]] && continue
    backend_name="$(backend_name_for_ip_port "$old_ip" "$port")"
    drain_backend_if_exists "$lb_id" "$backend_set" "$backend_name"
  done < "$ATTACHMENTS_FILE"
}

delete_old_backends_for_ip() {
  local old_ip="$1"
  local lb_id=""
  local backend_set=""
  local port=""
  local backend_name=""

  while IFS=$'	' read -r lb_id backend_set port; do
    [[ -z "$lb_id" ]] && continue
    backend_name="$(backend_name_for_ip_port "$old_ip" "$port")"
    delete_backend_if_exists "$lb_id" "$backend_set" "$backend_name"
  done < "$ATTACHMENTS_FILE"
}

rollout() {
  local original_size=""
  local surge_size=""
  local old_instance_id=""
  local old_ip=""
  local final_size=""

  load_lb_attachments
  validate_new_instance_config
  prepare_rollout_state

  original_size="$(cat "$STEADY_SIZE_FILE")"
  surge_size=$((original_size + SURGE_BY))

  log "Script version:           $SCRIPT_VERSION"
  log "Original target pool size: $original_size"
  log "Surge target pool size:    $surge_size"
  log "Replacement method:        $REPLACEMENT_METHOD"
  log "Rollout state dir:         $STATE_DIR"
  log "New instance config:       $NEW_INSTANCE_CONFIG_ID"
  log "Instances to replace:"
  sed 's/^/  /' "$OLD_IDS_FILE"

  if [[ "$REPLACEMENT_METHOD" == "terminate" ]]; then
    warn "terminate mode can recreate the stale pool-member problem. Use detach unless you are working around a detach service error."
  fi

  if [[ "$PRE_CLEAN_STALE_BACKENDS" == "true" ]]; then
    log "Cleaning stale/orphaned LB backends before rollout..."
    cleanup_orphaned_lb_backends
  else
    log "Skipping broad stale-backend cleanup before rollout. Use --pre-clean-stale-backends true or --cleanup-stale-backends-only when needed."
  fi

  log "Checking backend health before rollout..."
  wait_all_backend_sets_ok

  log "Updating pool to the new instance configuration..."
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

    log ""
    if is_done "$old_instance_id"; then
      log "Skipping already completed instance: $old_instance_id"
      continue
    fi

    if ! instance_in_pool "$old_instance_id"; then
      warn "Captured instance $old_instance_id is no longer in the pool; marking done after standalone cleanup."
      terminate_standalone_if_needed "$old_instance_id"
      mark_done "$old_instance_id"
      continue
    fi

    if ! is_valid_active_instance "$old_instance_id"; then
      warn "Captured instance $old_instance_id is no longer valid/active; skipping normal replacement."
      mark_done "$old_instance_id"
      continue
    fi

    old_ip="$(private_ip_for_instance "$old_instance_id")"
    log "Replacing old instance: $old_instance_id private_ip=$old_ip"

    scale_pool_to "$surge_size"
    wait_pool_running
    wait_valid_pool_count_at_least "$surge_size"
    wait_backend_counts_at_least "$surge_size"
    wait_all_backend_sets_ok

    drain_old_backends_for_ip "$old_ip"
    log "Waiting ${DRAIN_SECONDS}s for existing connections to drain..."
    sleep "$DRAIN_SECONDS"

    if [[ "$REPLACEMENT_METHOD" == "terminate" ]]; then
      safe_direct_terminate_and_restore_size "$old_instance_id" "$original_size"
    else
      safe_detach_terminate_decrement "$old_instance_id"
    fi

    delete_old_backends_for_ip "$old_ip"

    wait_pool_running
    wait_valid_pool_count_at_least "$original_size"
    wait_backend_counts_at_least "$original_size"
    wait_all_backend_sets_ok

    mark_done "$old_instance_id"
    log "Completed replacement for $old_instance_id"
  done < "$OLD_IDS_FILE"

  final_size="$(pool_size)"
  if [[ "$final_size" != "$original_size" ]]; then
    warn "Final pool target size is $final_size; resetting to $original_size"
    scale_pool_to "$original_size"
    wait_pool_running
  fi

  if [[ "$POST_CLEAN_STALE_BACKENDS" == "true" ]]; then
    log "Running final stale backend cleanup..."
    cleanup_orphaned_lb_backends
  else
    log "Skipping broad final stale-backend cleanup."
  fi
  wait_all_backend_sets_ok

  log ""
  log "Rolling replacement completed successfully."
  if [[ -s "$WARNINGS_FILE" ]]; then
    log "Warnings were recorded in: $WARNINGS_FILE"
  fi
}

cleanup_only() {
  load_lb_attachments
  cleanup_orphaned_lb_backends
  wait_all_backend_sets_ok
}

if [[ "$CLEANUP_STALE_BACKENDS_ONLY" == "true" ]]; then
  cleanup_only
else
  rollout
fi
