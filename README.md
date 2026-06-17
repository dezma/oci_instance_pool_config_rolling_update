# OCI Instance Pool Rolling Configuration Update

A Bash utility for rolling an Oracle Cloud Infrastructure (OCI) Compute instance pool to a new instance configuration while the pool is behind an OCI Load Balancer.

The script is designed for pools that serve traffic through one or more load balancer backend sets. It adds replacement capacity first, verifies that the replacement instance is healthy on the load balancer, drains the old backend, terminates the old instance, restores the pool target size, and removes old backend entries.

---

## What the script does

The script does not update running VMs in place. It replaces existing pool members with new instances created from the new instance configuration.

High-level flow:

```text
1. Validate the OCI CLI environment and required arguments.
2. Discover the load balancer backend attachments for the instance pool.
3. Capture valid running pool members as rollout targets.
4. Update the instance pool to the new instance configuration.
5. Temporarily scale the pool above the steady size.
6. Identify the exact replacement VM created by the scale-out operation.
7. Wait until that replacement VM is healthy on every selected backend set.
8. Drain the old VM from the selected backend sets.
9. Wait for the configured drain period.
10. Terminate the old VM.
11. Restore the pool target size.
12. Delete old backend entries from the selected backend sets.
13. Repeat until all captured rollout targets are replaced.
```

Example with a pool of size `2` and `--surge-by 1`:

```text
Initial pool:
  old-vm-1
  old-vm-2

Cycle 1:
  scale to 3
  wait for replacement-vm-1 to be healthy
  drain old-vm-1
  terminate old-vm-1
  scale back to 2

Cycle 2:
  scale to 3
  wait for replacement-vm-2 to be healthy
  drain old-vm-2
  terminate old-vm-2
  scale back to 2

Final pool:
  replacement-vm-1
  replacement-vm-2
```

---

## Safety model

The script uses a replacement-first strategy:

```text
Scale out -> verify replacement health -> drain old backend -> terminate old VM -> scale back
```

Key safety behavior:

- The script only uses pool members that exist in Compute, are `RUNNING`, and have a resolvable primary private IP.
- Old rollout targets may already be unhealthy, drained, or missing from a backend set.
- A new replacement VM must be healthy before the old VM is drained or terminated.
- Replacement health is checked per backend, not only at backend-set level.
- The replacement backend must be `OK`, not drained, and not offline on every selected backend set.
- The replacement must pass the health check for the configured number of consecutive checks.
- Stale or terminated historical pool records are ignored when choosing rollout targets.

This design allows the script to replace degraded old VMs while still refusing to remove old capacity when the new replacement is not ready.

---

## Requirements

Install and configure:

```text
bash
OCI CLI
jq
awk
sort
comm
```

Check locally:

```bash
oci --version
jq --version
```

Your OCI identity must be allowed to inspect or manage:

```text
Compute instances
Compute instance pools
Compute instance configurations
VNIC attachments and VNICs
Load balancers, backend sets, and backends
```

---

## Required OCI resources

Before running the script, you need:

```text
1. An existing OCI Compute instance pool.
2. A new instance configuration OCID.
3. An OCI Load Balancer attached to the instance pool.
4. Backend health checks that accurately represent application readiness.
5. Enough capacity, quota, and subnet IPs to temporarily add surge instances.
```

The script does not create a new image or instance configuration. Create the new instance configuration first, then pass its OCID to the script.

---

## Recommended usage

### 1. Make the script executable

```bash
chmod +x ./inst-config-update.sh
```

### 2. Run a rolling update across all pool-attached backend sets

This is the recommended mode for most instance pools behind an OCI Load Balancer.

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.<unique_id>" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --all-attached-backends \
  --steady-size 2 \
  --surge-by 1 \
  --drain-seconds 120 \
  --healthy-consecutive-checks 2 \
  --reset-rollout-state
```

Use `--all-attached-backends` when the instance pool already has load balancer attachments. The script reads the pool attachments and discovers the load balancer OCID, backend set names, backend ports, and attachment state.

### 3. Run against one backend set instead

Use this mode only when you want to manage a single backend set and port manually.

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.<unique_id>" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --lb-id "ocid1.loadbalancer.oc1.<region>.<unique_id>" \
  --backend-set-name "example-backend-set" \
  --app-port 8080 \
  --steady-size 2 \
  --surge-by 1 \
  --drain-seconds 120 \
  --healthy-consecutive-checks 2 \
  --reset-rollout-state
```

When using `--all-attached-backends`, do not pass `--lb-id`, `--backend-set-name`, or `--app-port`.

---

## Targeted replacement

Use targeted replacement when you want to replace only one known old pool member.

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.<unique_id>" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --all-attached-backends \
  --target-instance-id "ocid1.instance.oc1.<region>.<unique_id>" \
  --steady-size 2 \
  --surge-by 1 \
  --drain-seconds 120 \
  --healthy-consecutive-checks 2 \
  --reset-rollout-state
```

You can pass `--target-instance-id` more than once to replace a specific list of old instances.

---

## Cleanup-only mode

Cleanup-only mode removes load balancer backend entries whose IPs do not belong to valid `RUNNING` pool members.

Use this only when the selected backend sets are dedicated to the instance pool.

```bash
./inst-config-update.sh \
  --cleanup-stale-backends-only \
  --delete-orphan-backends true \
  --no-env-file \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --all-attached-backends
```

Do not use cleanup-only mode on shared backend sets that contain manually managed servers, blue/green targets, or non-pool backends that should remain.

---

## Resume behavior

The script stores rollout state in:

```text
./rolling-replace-state
```

You can override the location:

```bash
--rollout-state-dir ./my-rollout-state
```

Use `--reset-rollout-state` only when starting a fresh rollout.

Do not use `--reset-rollout-state` when resuming the same interrupted rollout. Rerun the same command without the reset flag:

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.<unique_id>" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --all-attached-backends \
  --steady-size 2
```

The script skips instance IDs already marked as complete and continues with remaining rollout targets.

---

## Environment file usage

You can pass values directly as CLI arguments or load them from an environment file.

Example `rollout.env`:

```bash
NEW_INSTANCE_CONFIG_ID="ocid1.instanceconfiguration.oc1.<region>.<unique_id>"
COMPARTMENT_ID="ocid1.compartment.oc1..<unique_id>"
INSTANCE_POOL_ID="ocid1.instancepool.oc1.<region>.<unique_id>"
STEADY_SIZE="2"
SURGE_BY="1"
DRAIN_SECONDS="120"
HEALTHY_CONSECUTIVE_CHECKS="2"
```

Run:

```bash
./inst-config-update.sh --env-file ./rollout.env --all-attached-backends --reset-rollout-state
```

Do not commit real environment files to a public repository.

---

## Argument reference

| Argument | Required | Description |
|---|---:|---|
| `--new-instance-config-id OCID` | Rollout only | New instance configuration to attach to the pool. |
| `--compartment-id OCID` | Yes | Compartment containing the pool instances. |
| `--instance-pool-id OCID` | Yes | Instance pool to update and roll. |
| `--all-attached-backends` | Backend selection | Discover all `ATTACHED` load balancer backend sets from the instance pool. |
| `--lb-id OCID` | Backend selection | Load balancer OCID for single-backend mode. |
| `--backend-set-name NAME` | Backend selection | Backend set name for single-backend mode. |
| `--app-port PORT` | Backend selection | Backend port for single-backend mode. |
| `--steady-size N` | Recommended | Desired final pool target size. Use this when recovering from a partially completed rollout. |
| `--surge-by N` | No | Extra capacity to create before removing each target. Default: `1`. |
| `--drain-seconds N` | No | Seconds to wait after draining old backends. Default: `120`. |
| `--target-instance-id OCID` | No | Replace only this old pool member. Can be repeated. |
| `--reset-rollout-state` | No | Start a fresh rollout state. |
| `--rollout-state-dir DIR` | No | State directory. Default: `./rolling-replace-state`. |
| `--healthy-consecutive-checks N` | No | Number of consecutive healthy checks required for the replacement VM. Default: `2`. |
| `--replacement-timeout-seconds N` | No | Timeout while waiting for replacement VM health. Default: `1800`. |
| `--poll-seconds N` | No | Polling interval. Default: `15`. |
| `--terminate-attempts N` | No | Number of attempts to submit the old-instance termination request. Default: `5`. |
| `--preserve-boot-volume true|false` | No | Whether to preserve old boot volumes when terminating old instances. Default: `false`. |
| `--force-replace-current-config true|false` | No | Also replace instances already created from the requested new instance configuration. Default: `false`. |
| `--cleanup-stale-backends-only` | No | Run only stale backend cleanup. Does not update the pool configuration or replace VMs. |
| `--delete-orphan-backends true` | Cleanup only | Required confirmation for cleanup-only deletion. |
| `--no-env-file` | No | Do not load values from an environment file. |
| `--env-file FILE` | No | Load values from a shell-compatible env file. |

Choose one backend selection mode:

```text
--all-attached-backends
```

or:

```text
--lb-id ... --backend-set-name ... --app-port ...
```

---

## Health checks

The script checks each replacement backend using OCI Load Balancer backend health. A replacement is considered ready only when it is:

```text
status = OK
drain  = false
offline = false
```

The replacement must satisfy this on every selected backend set for the configured number of consecutive checks.

If the replacement stays in `Critical`, `Warning`, `Pending`, `Incomplete`, or is missing from any selected backend set, the script stops before draining or terminating the old VM.

---

## Troubleshooting

### Replacement backend is `Critical - Connection failed`

Common causes:

- The application is not running on the replacement VM.
- The application is listening on a different port.
- The load balancer health check uses the wrong path, protocol, or port.
- NSG or security-list rules do not allow LB-to-backend traffic.
- The instance configuration is missing required VNIC or NSG settings.
- Cloud-init or startup scripts failed.
- A host firewall blocks the backend port.

Useful checks:

```bash
oci lb backend list \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME" \
  --all \
  --output table

oci lb backend-health get \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME" \
  --backend-name "<private-ip>:<port>"
```

On the VM:

```bash
sudo ss -lntp
sudo systemctl status <your-service> --no-pager
sudo journalctl -u <your-service> -n 100 --no-pager
sudo cloud-init status --long
curl -i http://127.0.0.1:<port>/<health-path>
```

### The script says no rollout targets were found

This usually means all valid running pool members already appear to use the requested new instance configuration.

To force recycling anyway:

```bash
--force-replace-current-config true
```

### The pool size is already above the steady size

Pass the intended final size explicitly:

```bash
--steady-size 2
```

This is useful after an interrupted rollout that already created replacement capacity.

### Stale terminated instances still appear in pool output

OCI may continue to show historical or terminated entries in some list output. The script filters those records by checking Compute state and VNIC presence before using them as rollout targets.

### Old backend entries remain on the load balancer

Run cleanup-only mode if the backend sets are dedicated to this pool:

```bash
./inst-config-update.sh \
  --cleanup-stale-backends-only \
  --delete-orphan-backends true \
  --no-env-file \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --all-attached-backends
```

---

## Operational guidance

- Run only one rollout against a given instance pool at a time.
- Pause or account for autoscaling policies that may change pool size during rollout.
- Set `--steady-size` explicitly when recovering from a partially completed rollout.
- Use `--target-instance-id` for targeted recovery.
- Keep `--surge-by` small unless you have verified quota, subnet IPs, and load balancer capacity.
- Increase `--drain-seconds` for long-running requests or persistent connections.
- Make sure the load balancer health check reflects real application readiness.

---

## Limitations

- Supports OCI Load Balancer through `oci lb`.
- Does not create custom images or instance configurations.
- Does not validate application correctness beyond load balancer backend health.
- Does not manage DNS traffic shifting.
- Does not manage autoscaling policies.
- Does not preserve old boot volumes unless `--preserve-boot-volume true` is set.
- Cleanup-only mode should only be used on backend sets dedicated to the instance pool.

---

## OCI documentation

- Updating the instance configuration for an instance pool:  
  https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/updatinginstancepool-updating-instance-configuration.htm

- Updating instance pool size:  
  https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/updatinginstancepool_topic-update-instance-pool-size.htm

- Creating instance pools and attaching load balancers:  
  https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/creatinginstancepool.htm

- OCI CLI instance pool update:  
  https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute-management/instance-pool/update.html

- OCI CLI load balancer backend update:  
  https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/lb/backend/update.html

- OCI CLI compute instance terminate:  
  https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/instance/terminate.html

---

