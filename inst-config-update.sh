#!/usr/bin/env bash
# OCI instance-pool rolling replacement controller.
# Version: v13
#
# Purpose:
#   Replace instance-pool members with instances created from a new instance
#   configuration without using the detachInstance API path.
#
# Safety model:
#   - Old targets may already be Critical/drained/unhealthy.
#   - The script ignores old-target health, but requires the explicit newly
#     created replacement VM(s) to be OK in every selected LB backend set before
#     draining/removing old targets.
#   - The script never calls:
#       oci compute-management instance-pool-instance detach
#     because repeated 500 InternalError responses from that endpoint were seen.

set -Eeuo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

SCRIPT_VERSION="2026-06-17-v13-no-detach-controller"

NEW_INSTANCE_CONFIG_ID="${NEW_INSTANCE_CONFIG_ID:-}"
COMPARTMENT_ID="${COMPARTMENT_ID:-}"
INSTANCE_POOL_ID="${INSTANCE_POOL_ID:-}"
LB_ID="${LB_ID:-}"
BACKEND_SET_NAME="${BACKEND_SET_NAME:-}"
APP_PORT="${APP_PORT:-}"
ALL_ATTACHED_BACKENDS="false"
NO_ENV_FILE="false"
ENV_FILE="${ENV_FILE:-}"
ROLLOUT_STATE_DIR="${ROLLOUT_STATE_DIR:-./rolling-replace-state}"
RESET_ROLLOUT_STATE="false"
CLEANUP_STALE_BACKENDS_ONLY="false"
DELETE_ORPHAN_BACKENDS="false"
TARGET_INSTANCE_IDS=()
STEADY_SIZE="${STEADY_SIZE:-}"
SURGE_BY="${SURGE_BY:-1}"
DRAIN_SECONDS="${DRAIN_SECONDS:-120}"
HEALTHY_CONSECUTIVE_CHECKS="${HEALTHY_CONSECUTIVE_CHECKS:-2}"
REPLACEMENT_TIMEOUT_SECONDS="${REPLACEMENT_TIMEOUT_SECONDS:-1800}"
POLL_SECONDS="${POLL_SECONDS:-15}"
TERMINATE_ATTEMPTS="${TERMINATE_ATTEMPTS:-5}"
FORCE_REPLACE_CURRENT_CONFIG="false"
PRESERVE_BOOT_VOLUME="false"

usage() {
  cat <<'USAGE'
Usage:
  inst-config-update.sh [options]

Required for rollout:
  --new-instance-config-id OCID       New instance configuration to attach to the pool.
  --compartment-id OCID               Compartment containing the pool instances.
  --instance-pool-id OCID             Instance pool to update/roll.

Backend selection, choose one:
  --all-attached-backends             Discover all ATTACHED LB backend sets from the pool.
  --lb-id OCID --backend-set-name NAME --app-port PORT
                                      Use one specific LB backend set and backend port.

Important options:
  --steady-size N                     Desired final pool target size. Strongly recommended
                                      when recovering from a failed/surged rollout.
  --surge-by N                        Extra capacity to create before removing each target.
                                      Default: 1.
  --drain-seconds N                   Seconds to wait after draining old backends.
                                      Default: 120.
  --target-instance-id OCID           Replace only this old pool member. Can be repeated.
  --reset-rollout-state               Start a fresh rollout state.
  --rollout-state-dir DIR             State directory. Default: ./rolling-replace-state.
  --healthy-consecutive-checks N      Replacement must be OK for N checks. Default: 2.
  --replacement-timeout-seconds N     Timeout waiting for explicit replacement health.
                                      Default: 1800.
  --cleanup-stale-backends-only       Only remove LB backends whose IPs do not belong to
                                      valid RUNNING pool members. Requires
                                      --delete-orphan-backends true.
  --delete-orphan-backends true       Allow cleanup-only mode to delete orphan LB entries.
  --force-replace-current-config true Also replace instances already created from the new
                                      instance configuration. Default: false.
  --no-env-file                       Do not read an env file.
  --env-file FILE                     Optionally load variables from a file.

Unsupported on purpose:
  --replacement-method detach         Refused. This version never calls detachInstance.

Examples:
  # Normal multi-backend rollout:
  ./inst-config-update.sh \
    --no-env-file \
    --new-instance-config-id "$NEW_INSTANCE_CONFIG_ID" \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --all-attached-backends \
    --steady-size 1 \
    --surge-by 1 \
    --drain-seconds 120 \
    --reset-rollout-state

  # Targeted recovery for one old VM after a failed rollout:
  ./inst-config-update.sh \
    --no-env-file \
    --new-instance-config-id "$NEW_INSTANCE_CONFIG_ID" \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --all-attached-backends \
    --target-instance-id "$OLD_INSTANCE_ID" \
    --steady-size 1 \
    --reset-rollout-state
USAGE
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "missing dependency: $1"
}

bool_value() {
  case "${1,,}" in
    true|yes|y|1) echo "true" ;;
    false|no|n|0) echo "false" ;;
    *) fatal "invalid boolean value: $1" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --version) echo "$SCRIPT_VERSION"; exit 0 ;;
    --no-env-file) NO_ENV_FILE="true"; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --new-instance-config-id) NEW_INSTANCE_CONFIG_ID="$2"; shift 2 ;;
    --compartment-id) COMPARTMENT_ID="$2"; shift 2 ;;
    --instance-pool-id) INSTANCE_POOL_ID="$2"; shift 2 ;;
    --lb-id) LB_ID="$2"; shift 2 ;;
    --backend-set-name) BACKEND_SET_NAME="$2"; shift 2 ;;
    --app-port) APP_PORT="$2"; shift 2 ;;
    --all-attached-backends) ALL_ATTACHED_BACKENDS="true"; shift ;;
    --rollout-state-dir) ROLLOUT_STATE_DIR="$2"; shift 2 ;;
    --reset-rollout-state) RESET_ROLLOUT_STATE="true"; shift ;;
    --cleanup-stale-backends-only) CLEANUP_STALE_BACKENDS_ONLY="true"; shift ;;
    --delete-orphan-backends) DELETE_ORPHAN_BACKENDS="$(bool_value "$2")"; shift 2 ;;
    --target-instance-id) TARGET_INSTANCE_IDS+=("$2"); shift 2 ;;
    --steady-size) STEADY_SIZE="$2"; shift 2 ;;
    --surge-by) SURGE_BY="$2"; shift 2 ;;
    --drain-seconds) DRAIN_SECONDS="$2"; shift 2 ;;
    --healthy-consecutive-checks) HEALTHY_CONSECUTIVE_CHECKS="$2"; shift 2 ;;
    --replacement-timeout-seconds) REPLACEMENT_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --terminate-attempts) TERMINATE_ATTEMPTS="$2"; shift 2 ;;
    --force-replace-current-config) FORCE_REPLACE_CURRENT_CONFIG="$(bool_value "$2")"; shift 2 ;;
    --preserve-boot-volume) PRESERVE_BOOT_VOLUME="$(bool_value "$2")"; shift 2 ;;
    --replacement-method)
      case "$2" in
        detach) fatal "--replacement-method detach is disabled in v13 because detachInstance repeatedly returned OCI 500 InternalError" ;;
        terminate|direct-terminate|no-detach) shift 2 ;;
        *) fatal "unsupported --replacement-method value: $2" ;;
      esac
      ;;
    *) fatal "unknown argument: $1" ;;
  esac
done

if [ "$NO_ENV_FILE" != "true" ] && [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || fatal "cannot find env file: $ENV_FILE"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

need_cmd oci
need_cmd jq
need_cmd awk
need_cmd sort
need_cmd comm

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_int "$SURGE_BY" || fatal "--surge-by must be an integer"
is_int "$DRAIN_SECONDS" || fatal "--drain-seconds must be an integer"
is_int "$HEALTHY_CONSECUTIVE_CHECKS" || fatal "--healthy-consecutive-checks must be an integer"
is_int "$REPLACEMENT_TIMEOUT_SECONDS" || fatal "--replacement-timeout-seconds must be an integer"
is_int "$POLL_SECONDS" || fatal "--poll-seconds must be an integer"
is_int "$TERMINATE_ATTEMPTS" || fatal "--terminate-attempts must be an integer"

[ -n "$COMPARTMENT_ID" ] || fatal "--compartment-id is required"
[ -n "$INSTANCE_POOL_ID" ] || fatal "--instance-pool-id is required"

if [ "$CLEANUP_STALE_BACKENDS_ONLY" != "true" ]; then
  [ -n "$NEW_INSTANCE_CONFIG_ID" ] || fatal "--new-instance-config-id is required for rollout"
fi

if [ "$ALL_ATTACHED_BACKENDS" = "true" ]; then
  :
else
  [ -n "$LB_ID" ] || fatal "--lb-id is required unless --all-attached-backends is used"
  [ -n "$BACKEND_SET_NAME" ] || fatal "--backend-set-name is required unless --all-attached-backends is used"
  [ -n "$APP_PORT" ] || fatal "--app-port is required unless --all-attached-backends is used"
fi

mkdir -p "$ROLLOUT_STATE_DIR"
ATTACHMENTS_FILE="$ROLLOUT_STATE_DIR/lb-attachments.tsv"
TARGETS_FILE="$ROLLOUT_STATE_DIR/old-targets.tsv"
DONE_FILE="$ROLLOUT_STATE_DIR/done-instance-ids.txt"
SUMMARY_FILE="$ROLLOUT_STATE_DIR/summary.log"

oci_json() {
  oci "$@" --output json
}

pool_get() {
  oci_json compute-management instance-pool get --instance-pool-id "$INSTANCE_POOL_ID"
}

pool_size() {
  pool_get | jq -r '.data.size'
}

wait_pool_running() {
  local state
  log "Waiting for instance pool to be RUNNING..."
  while true; do
    state=$(pool_get | jq -r '.data."lifecycle-state"')
    log "  pool state: $state"
    [ "$state" = "RUNNING" ] && return 0
    sleep "$POLL_SECONDS"
  done
}

scale_pool_to() {
  local desired="$1"
  local current
  current=$(pool_size)
  if [ "$current" = "$desired" ]; then
    log "Pool already has target size $desired."
    return 0
  fi
  log "Scaling pool target size from $current to $desired..."
  oci compute-management instance-pool update \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --size "$desired" \
    --wait-for-state RUNNING >/dev/null
  wait_pool_running
}

load_attachments() {
  : > "$ATTACHMENTS_FILE"
  if [ "$ALL_ATTACHED_BACKENDS" = "true" ]; then
    log "Discovering ATTACHED load balancer attachments from instance pool..."
    pool_get | jq -r '
      .data."load-balancers"[]?
      | select(."lifecycle-state" == "ATTACHED")
      | [."load-balancer-id", ."backend-set-name", (.port|tostring)]
      | @tsv
    ' > "$ATTACHMENTS_FILE"
  else
    printf '%s\t%s\t%s\n' "$LB_ID" "$BACKEND_SET_NAME" "$APP_PORT" > "$ATTACHMENTS_FILE"
  fi
  [ -s "$ATTACHMENTS_FILE" ] || fatal "no load balancer backend attachments selected"
  log "Selected backend attachments:"
  awk -F '\t' '{printf "  lb=%s backend_set=%s port=%s\n", $1, $2, $3}' "$ATTACHMENTS_FILE"
}

instance_json() {
  local id="$1"
  oci_json compute instance get --instance-id "$id" 2>/dev/null || return 1
}

instance_state() {
  local id="$1"
  instance_json "$id" | jq -r '.data."lifecycle-state"' 2>/dev/null || echo "NOT_FOUND"
}

instance_config_id() {
  local id="$1"
  instance_json "$id" | jq -r '.data."instance-configuration-id" // ""' 2>/dev/null || echo ""
}

primary_private_ip() {
  local id="$1"
  local vnic_ids vnic_id primary_ip fallback_ip is_primary
  vnic_ids=$(oci_json compute vnic-attachment list \
      --compartment-id "$COMPARTMENT_ID" \
      --instance-id "$id" \
      --all 2>/dev/null \
    | jq -r '.data[] | select(."lifecycle-state" == "ATTACHED") | ."vnic-id"' 2>/dev/null) || return 1
  [ -n "$vnic_ids" ] || return 1
  fallback_ip=""
  while IFS= read -r vnic_id; do
    [ -n "$vnic_id" ] || continue
    local vnic_json
    vnic_json=$(oci_json network vnic get --vnic-id "$vnic_id" 2>/dev/null) || continue
    is_primary=$(jq -r '.data."is-primary" // false' <<<"$vnic_json")
    primary_ip=$(jq -r '.data."private-ip" // empty' <<<"$vnic_json")
    [ -z "$fallback_ip" ] && fallback_ip="$primary_ip"
    if [ "$is_primary" = "true" ] && [ -n "$primary_ip" ]; then
      echo "$primary_ip"
      return 0
    fi
  done <<<"$vnic_ids"
  [ -n "$fallback_ip" ] || return 1
  echo "$fallback_ip"
}

pool_instance_ids_raw() {
  oci_json compute-management instance-pool list-instances \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --all \
  | jq -r '.data[].id'
}

list_valid_running_pool_instances() {
  local id state ip cfg
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    state=$(instance_state "$id")
    [ "$state" = "RUNNING" ] || continue
    ip=$(primary_private_ip "$id" 2>/dev/null || true)
    [ -n "$ip" ] || continue
    cfg=$(instance_config_id "$id")
    printf '%s\t%s\t%s\t%s\n' "$id" "$ip" "$state" "$cfg"
  done < <(pool_instance_ids_raw | sort -u)
}

valid_ids_file() {
  local out="$1"
  list_valid_running_pool_instances | cut -f1 | sort -u > "$out"
}

backend_name() {
  local ip="$1" port="$2"
  printf '%s:%s' "$ip" "$port"
}

backend_get_json() {
  local lb="$1" bs="$2" name="$3"
  oci_json lb backend get \
    --load-balancer-id "$lb" \
    --backend-set-name "$bs" \
    --backend-name "$name" 2>/dev/null || return 1
}

backend_exists() {
  backend_get_json "$1" "$2" "$3" >/dev/null 2>&1
}

backend_status() {
  local lb="$1" bs="$2" name="$3"
  oci_json lb backend-health get \
    --load-balancer-id "$lb" \
    --backend-set-name "$bs" \
    --backend-name "$name" 2>/dev/null \
    | jq -r '.data.status // "UNKNOWN"' 2>/dev/null || echo "MISSING"
}

backend_drain_flag() {
  local lb="$1" bs="$2" name="$3"
  backend_get_json "$lb" "$bs" "$name" | jq -r '.data.drain // false' 2>/dev/null || echo "unknown"
}

backend_offline_flag() {
  local lb="$1" bs="$2" name="$3"
  backend_get_json "$lb" "$bs" "$name" | jq -r '.data.offline // false' 2>/dev/null || echo "unknown"
}

drain_backend_if_exists() {
  local lb="$1" bs="$2" ip="$3" port="$4" name
  name=$(backend_name "$ip" "$port")
  if ! backend_exists "$lb" "$bs" "$name"; then
    warn "backend $name not present in $bs; skipping drain"
    return 0
  fi
  log "Draining backend $name in $bs..."
  oci lb backend update \
    --load-balancer-id "$lb" \
    --backend-set-name "$bs" \
    --backend-name "$name" \
    --backup false \
    --drain true \
    --offline false \
    --weight 1 \
    --wait-for-state SUCCEEDED >/dev/null
}

delete_backend_if_exists() {
  local lb="$1" bs="$2" ip="$3" port="$4" name
  name=$(backend_name "$ip" "$port")
  if ! backend_exists "$lb" "$bs" "$name"; then
    return 0
  fi
  log "Deleting backend $name from $bs..."
  oci lb backend delete \
    --load-balancer-id "$lb" \
    --backend-set-name "$bs" \
    --backend-name "$name" \
    --force \
    --wait-for-state SUCCEEDED >/dev/null
}

drain_old_ip_all_attachments() {
  local ip="$1" lb bs port
  while IFS=$'\t' read -r lb bs port; do
    drain_backend_if_exists "$lb" "$bs" "$ip" "$port"
  done < "$ATTACHMENTS_FILE"
}

delete_old_ip_all_attachments() {
  local ip="$1" lb bs port
  while IFS=$'\t' read -r lb bs port; do
    delete_backend_if_exists "$lb" "$bs" "$ip" "$port"
  done < "$ATTACHMENTS_FILE"
}

backend_ready_for_ip_all_attachments() {
  local ip="$1" lb bs port name status drain offline bad=0
  while IFS=$'\t' read -r lb bs port; do
    name=$(backend_name "$ip" "$port")
    status=$(backend_status "$lb" "$bs" "$name")
    drain=$(backend_drain_flag "$lb" "$bs" "$name")
    offline=$(backend_offline_flag "$lb" "$bs" "$name")
    if [ "$status" != "OK" ] || [ "$drain" != "false" ] || [ "$offline" != "false" ]; then
      printf '    %s %s status=%s drain=%s offline=%s\n' "$bs" "$name" "$status" "$drain" "$offline"
      bad=1
    fi
  done < "$ATTACHMENTS_FILE"
  [ "$bad" -eq 0 ]
}

wait_explicit_replacements_ready() {
  local ids_file="$1" expected_min="$2" start now consecutive total ready bad id ip
  start=$(date +%s)
  consecutive=0
  log "Waiting for explicit replacement VM backend health..."
  log "  expected replacement VM count: at least $expected_min"
  while true; do
    total=0
    ready=0
    bad=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      state=$(instance_state "$id")
      if [ "$state" != "RUNNING" ]; then
        printf '    %s state=%s not ready\n' "$id" "$state"
        bad=$((bad + 1))
        total=$((total + 1))
        continue
      fi
      ip=$(primary_private_ip "$id" 2>/dev/null || true)
      if [ -z "$ip" ]; then
        printf '    %s has no primary private IP yet\n' "$id"
        bad=$((bad + 1))
        total=$((total + 1))
        continue
      fi
      total=$((total + 1))
      if backend_ready_for_ip_all_attachments "$ip"; then
        ready=$((ready + 1))
      else
        bad=$((bad + 1))
      fi
    done < "$ids_file"

    log "  explicit replacement readiness: total=$total ready=$ready bad=$bad consecutive_ok=$consecutive/$HEALTHY_CONSECUTIVE_CHECKS"
    if [ "$total" -ge "$expected_min" ] && [ "$ready" -ge "$expected_min" ] && [ "$bad" -eq 0 ]; then
      consecutive=$((consecutive + 1))
      if [ "$consecutive" -ge "$HEALTHY_CONSECUTIVE_CHECKS" ]; then
        log "Explicit replacement backend readiness passed."
        return 0
      fi
    else
      consecutive=0
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$REPLACEMENT_TIMEOUT_SECONDS" ]; then
      fatal "replacement VM(s) did not become healthy in every selected backend set; refusing to drain/remove old VM"
    fi
    sleep "$POLL_SECONDS"
  done
}

capture_targets() {
  : > "$TARGETS_FILE"
  if [ "${#TARGET_INSTANCE_IDS[@]}" -gt 0 ]; then
    local id state ip cfg
    for id in "${TARGET_INSTANCE_IDS[@]}"; do
      state=$(instance_state "$id")
      [ "$state" = "NOT_FOUND" ] && fatal "target instance not found: $id"
      ip=$(primary_private_ip "$id" 2>/dev/null || true)
      cfg=$(instance_config_id "$id")
      printf '%s\t%s\t%s\n' "$id" "$ip" "$cfg" >> "$TARGETS_FILE"
    done
    return 0
  fi

  local row id ip state cfg
  while IFS=$'\t' read -r id ip state cfg; do
    if [ "$FORCE_REPLACE_CURRENT_CONFIG" = "true" ] || [ "$cfg" != "$NEW_INSTANCE_CONFIG_ID" ]; then
      printf '%s\t%s\t%s\n' "$id" "$ip" "$cfg" >> "$TARGETS_FILE"
    fi
  done < <(list_valid_running_pool_instances)
}

is_done() {
  local id="$1"
  [ -f "$DONE_FILE" ] && grep -Fxq "$id" "$DONE_FILE"
}

mark_done() {
  local id="$1"
  touch "$DONE_FILE"
  grep -Fxq "$id" "$DONE_FILE" 2>/dev/null || echo "$id" >> "$DONE_FILE"
}

update_pool_config() {
  log "Updating pool to new instance configuration..."
  oci compute-management instance-pool update \
    --instance-pool-id "$INSTANCE_POOL_ID" \
    --instance-configuration-id "$NEW_INSTANCE_CONFIG_ID" \
    --wait-for-state RUNNING >/dev/null
  wait_pool_running
}

terminate_instance_direct() {
  local id="$1" attempt state
  for attempt in $(seq 1 "$TERMINATE_ATTEMPTS"); do
    state=$(instance_state "$id")
    if [ "$state" = "TERMINATED" ] || [ "$state" = "NOT_FOUND" ]; then
      log "Instance $id is already $state."
      return 0
    fi
    log "Directly terminating old pool member, attempt $attempt/$TERMINATE_ATTEMPTS: $id"
    if oci compute instance terminate \
      --instance-id "$id" \
      --preserve-boot-volume "$PRESERVE_BOOT_VOLUME" \
      --force >/dev/null; then
      log "Terminate request accepted for $id."
      return 0
    fi
    warn "terminate request failed; checking state before retry"
    sleep $((attempt * 20))
  done
  fatal "failed to submit terminate request for $id"
}

wait_instance_terminated_or_not_found() {
  local id="$1" state start now
  start=$(date +%s)
  while true; do
    state=$(instance_state "$id")
    log "  old instance state: $state"
    if [ "$state" = "TERMINATED" ] || [ "$state" = "NOT_FOUND" ]; then
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge 1800 ]; then
      warn "old instance did not reach TERMINATED within wait window: $id"
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
}

cleanup_orphan_backends() {
  [ "$DELETE_ORPHAN_BACKENDS" = "true" ] || fatal "cleanup-only mode requires --delete-orphan-backends true"
  local active_ips_file lb bs port backends name ip p
  active_ips_file="$ROLLOUT_STATE_DIR/active-pool-ips.txt"
  list_valid_running_pool_instances | cut -f2 | sort -u > "$active_ips_file"
  log "Active RUNNING pool IPs kept during cleanup:"
  sed 's/^/  /' "$active_ips_file" || true

  while IFS=$'\t' read -r lb bs port; do
    log "Checking orphan backends in $bs port $port..."
    backends=$(oci_json lb backend list \
      --load-balancer-id "$lb" \
      --backend-set-name "$bs" \
      --all \
      | jq -r --argjson port "$port" '.data[] | select(.port == $port) | .name')
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      ip=${name%:*}
      p=${name##*:}
      [ "$p" = "$port" ] || continue
      if ! grep -Fxq "$ip" "$active_ips_file"; then
        log "Deleting orphan backend $name from $bs; IP is not a valid RUNNING pool member."
        oci lb backend delete \
          --load-balancer-id "$lb" \
          --backend-set-name "$bs" \
          --backend-name "$name" \
          --force \
          --wait-for-state SUCCEEDED >/dev/null
      fi
    done <<<"$backends"
  done < "$ATTACHMENTS_FILE"
}

build_replacement_ids_file() {
  local before_file="$1" after_file="$2" out_file="$3" fallback_file="$4"
  comm -13 "$before_file" "$after_file" > "$out_file"
  if [ ! -s "$out_file" ]; then
    warn "no newly created replacement ID detected from before/after pool diff"
    warn "falling back to RUNNING pool instances created from the new instance configuration and not in the old target set"
    : > "$fallback_file"
    local id ip state cfg
    while IFS=$'\t' read -r id ip state cfg; do
      [ "$cfg" = "$NEW_INSTANCE_CONFIG_ID" ] || continue
      if ! cut -f1 "$TARGETS_FILE" | grep -Fxq "$id"; then
        echo "$id" >> "$fallback_file"
      fi
    done < <(list_valid_running_pool_instances)
    sort -u "$fallback_file" > "$out_file"
  fi
}

rollout() {
  local original_size desired_surge old_id old_ip old_cfg before_file after_file repl_file fallback_file current_size row

  if [ "$RESET_ROLLOUT_STATE" = "true" ]; then
    log "Resetting rollout state directory: $ROLLOUT_STATE_DIR"
    rm -rf "$ROLLOUT_STATE_DIR"
    mkdir -p "$ROLLOUT_STATE_DIR"
    ATTACHMENTS_FILE="$ROLLOUT_STATE_DIR/lb-attachments.tsv"
    TARGETS_FILE="$ROLLOUT_STATE_DIR/old-targets.tsv"
    DONE_FILE="$ROLLOUT_STATE_DIR/done-instance-ids.txt"
    SUMMARY_FILE="$ROLLOUT_STATE_DIR/summary.log"
  fi

  load_attachments

  if [ "$CLEANUP_STALE_BACKENDS_ONLY" = "true" ]; then
    cleanup_orphan_backends
    log "Cleanup-only mode completed."
    return 0
  fi

  oci compute-management instance-configuration get \
    --instance-configuration-id "$NEW_INSTANCE_CONFIG_ID" >/dev/null

  if [ -n "$STEADY_SIZE" ]; then
    is_int "$STEADY_SIZE" || fatal "--steady-size must be an integer"
    original_size="$STEADY_SIZE"
  else
    original_size=$(pool_size)
  fi
  desired_surge=$((original_size + SURGE_BY))

  if [ ! -s "$TARGETS_FILE" ] || [ "$RESET_ROLLOUT_STATE" = "true" ]; then
    log "Capturing old rollout targets..."
    capture_targets
  else
    log "Using existing rollout target list: $TARGETS_FILE"
  fi

  if [ ! -s "$TARGETS_FILE" ]; then
    log "No rollout targets found. Instances already appear to use the requested instance configuration."
    return 0
  fi

  log "Rollout summary:"
  log "  script version:       $SCRIPT_VERSION"
  log "  steady size:          $original_size"
  log "  surge target size:    $desired_surge"
  log "  replacement method:   direct compute terminate; detachInstance is never called"
  log "  new instance config:  $NEW_INSTANCE_CONFIG_ID"
  log "  state dir:            $ROLLOUT_STATE_DIR"
  log "  targets:"
  awk -F '\t' '{printf "    id=%s ip=%s current_config=%s\n", $1, $2, $3}' "$TARGETS_FILE"

  update_pool_config

  while IFS=$'\t' read -r old_id old_ip old_cfg; do
    [ -n "$old_id" ] || continue
    if is_done "$old_id"; then
      log "Skipping already completed target: $old_id"
      continue
    fi

    log ""
    log "Replacing old instance: $old_id private_ip=${old_ip:-unknown}"

    if [ "$(instance_state "$old_id")" = "NOT_FOUND" ]; then
      warn "target instance is already not found; deleting saved old backends if IP is known"
      [ -n "$old_ip" ] && delete_old_ip_all_attachments "$old_ip"
      mark_done "$old_id"
      continue
    fi

    if [ -z "$old_ip" ]; then
      old_ip=$(primary_private_ip "$old_id" 2>/dev/null || true)
    fi
    [ -n "$old_ip" ] || fatal "cannot resolve old instance private IP for $old_id; refusing to continue"

    before_file="$ROLLOUT_STATE_DIR/before-${old_id}.ids"
    after_file="$ROLLOUT_STATE_DIR/after-${old_id}.ids"
    repl_file="$ROLLOUT_STATE_DIR/replacement-${old_id}.ids"
    fallback_file="$ROLLOUT_STATE_DIR/fallback-${old_id}.ids"

    valid_ids_file "$before_file"

    current_size=$(pool_size)
    if [ "$current_size" -lt "$desired_surge" ]; then
      scale_pool_to "$desired_surge"
    else
      log "Pool already has target size $current_size, which is >= surge target $desired_surge."
      wait_pool_running
    fi

    log "Waiting for at least $desired_surge valid RUNNING pool instance(s)..."
    local count start now
    start=$(date +%s)
    while true; do
      valid_ids_file "$after_file"
      count=$(wc -l < "$after_file" | tr -d ' ')
      log "  valid RUNNING pool instances: $count"
      [ "$count" -ge "$desired_surge" ] && break
      now=$(date +%s)
      if [ $((now - start)) -ge "$REPLACEMENT_TIMEOUT_SECONDS" ]; then
        fatal "pool did not reach required valid RUNNING instance count after surge"
      fi
      sleep "$POLL_SECONDS"
    done

    build_replacement_ids_file "$before_file" "$after_file" "$repl_file" "$fallback_file"
    log "Explicit replacement candidate ID(s) for this cycle:"
    sed 's/^/  /' "$repl_file" || true
    [ -s "$repl_file" ] || fatal "no replacement candidates found; refusing to drain old instance"

    wait_explicit_replacements_ready "$repl_file" "$SURGE_BY"

    log "Replacement is healthy. Old target may be degraded; draining it now if backend exists."
    drain_old_ip_all_attachments "$old_ip"
    log "Waiting ${DRAIN_SECONDS}s for existing connections to drain..."
    sleep "$DRAIN_SECONDS"

    terminate_instance_direct "$old_id"

    log "Restoring pool target size to steady size $original_size after direct termination request..."
    scale_pool_to "$original_size"

    log "Waiting for old instance termination/not-found..."
    wait_instance_terminated_or_not_found "$old_id"

    log "Deleting old backend entries from all selected backend sets..."
    delete_old_ip_all_attachments "$old_ip"

    log "Verifying replacement candidate(s) still healthy after old removal..."
    wait_explicit_replacements_ready "$repl_file" 1

    mark_done "$old_id"
    printf 'completed\t%s\t%s\n' "$old_id" "$old_ip" >> "$SUMMARY_FILE"
    log "Completed replacement for $old_id"
  done < "$TARGETS_FILE"

  log ""
  log "Rolling replacement completed."
  log "Note: OCI may still show terminated/not-found historical pool members in list output for a while. This script filters them by Compute state and VNIC before using them."
}

rollout
