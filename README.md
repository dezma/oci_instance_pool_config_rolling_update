# OCI Instance Pool Rolling Update Controller

A Bash controller for rolling an Oracle Cloud Infrastructure (OCI) instance pool to a new instance configuration while avoiding the `detachInstance` API path.

The script is designed for OCI instance pools that are attached to an OCI Load Balancer. It updates the pool to a new instance configuration, creates replacement capacity, verifies the exact replacement VM is healthy in the load balancer, drains the old VM, terminates the old VM directly, restores the pool to the desired steady size, and removes old load balancer backend entries.

> Script: `inst-config-update.sh`
>
> Version: `2026-06-17-v13-no-detach-controller`

---

## Why this script exists

OCI instance pools do not automatically update already-running instances when the pool is pointed to a new instance configuration. Updating the pool changes what future instances are created from; existing VMs must still be replaced.

The usual clean replacement path is to detach old pool members with auto-termination. In some environments, the OCI Compute Management detach operation can repeatedly return a service-side `500 InternalError` for pool members. This script avoids that recurring failure path by **not calling**:

```bash
oci compute-management instance-pool-instance detach
```

Instead, it uses a controlled no-detach workflow:

```text
surge capacity -> verify exact replacement VM health -> drain old backend -> terminate old compute instance -> scale pool back -> delete stale backend entries
```

This is a workaround for environments where `detachInstance` is unreliable. If the native detach workflow works reliably in your tenancy, it is generally the cleaner OCI-managed path.

---

## What the script does

For each old VM selected for replacement, the script performs this sequence:

```text
1. Discover load balancer backend attachments.
2. Update the instance pool to the new instance configuration.
3. Capture valid old pool targets.
4. Scale the pool from steady size N to N + surge.
5. Identify the exact replacement instance created by the surge.
6. Wait until that exact replacement VM is healthy in every selected backend set.
7. Drain the old VM's backend entries.
8. Wait the configured drain period.
9. Terminate the old VM directly with OCI Compute.
10. Restore the pool target size to the desired steady size.
11. Delete old backend entries from every selected backend set.
12. Verify the replacement backend remains healthy.
13. Save local rollout state so interrupted runs can be resumed.
```

The script intentionally filters out stale pool records by checking the real Compute instance state and attached VNICs. It only treats a pool member as valid if the instance exists, is `RUNNING`, and has a resolvable private IP.

---

## Key safety behavior

### It does not require the old VM to be healthy

The old VM may already be degraded before the script starts:

```text
Critical - Connection failed
Drained
Missing from one backend set
Unhealthy in the load balancer
```

That is allowed. The old VM is the thing being replaced.

### It does require the new replacement VM to be healthy

Before the script drains or terminates the old VM, the exact replacement VM created during the current surge cycle must be:

```text
RUNNING
registered in every selected backend set
backend health status OK
not drained
not offline
OK for the configured number of consecutive checks
```

This prevents the dangerous case where an old healthy VM is drained while the new VM is still `Critical`.

### It handles multiple backend sets

With `--all-attached-backends`, the script discovers every `ATTACHED` load balancer backend set from the instance pool and handles each backend set/port during readiness checks, drain, and cleanup.

Example pool attachments:

```text
backend-set-a : 8080
backend-set-b : 2080
backend-set-c : 9080
```

The old VM backend is drained and removed from all selected backend sets, not just one.

---

## Important design choice: no detach

This v13 script never calls:

```bash
oci compute-management instance-pool-instance detach
```

Instead, it directly terminates old instances with:

```bash
oci compute instance terminate
```

By default, the script uses:

```bash
--preserve-boot-volume false
```

That means old instance boot volumes are deleted unless you explicitly pass:

```bash
--preserve-boot-volume true
```

Because this script avoids instance-pool detach, OCI can sometimes still show historical, terminated, or stale pool-member records for a period of time. The script accounts for that by filtering pool list output using real Compute instance state and VNIC checks.

If a terminated or not-found instance remains visible as a pool member for a long time, open an OCI Support Request and include the affected instance pool OCID, stale instance OCIDs, and any failed `detachInstance` `opc-request-id` values.

---

## Requirements

### Local tools

Install these before running the script:

```text
bash
oci
jq
awk
sort
comm
```

Check locally:

```bash
bash --version
oci --version
jq --version
```

Validate the script syntax:

```bash
bash -n ./inst-config-update.sh
```

Check the script version:

```bash
./inst-config-update.sh --version
```

Expected:

```text
2026-06-17-v13-no-detach-controller
```

### OCI setup

You need:

```text
An OCI instance pool
A new instance configuration OCID
An OCI Load Balancer attached to the instance pool
Backend health checks that accurately detect application readiness
Enough service limits and capacity for N + surge instances
IAM permissions to manage compute instances, instance pools, VNICs, and load balancer backends
```

### Backend/VNIC assumption

The script resolves the backend IP using the instance's primary private IP. It is intended for instance pool load balancer attachments that use:

```text
PrimaryVnic
```

If your pool attachment uses a secondary VNIC selection, modify the script before use. The v13 script discovers backend set names and ports, but it does not currently resolve secondary VNIC display-name selections.

---

## Recommended usage

### Multi-backend rollout

Use this when the instance pool is attached to one or more load balancer backend sets and you want the script to discover them automatically.

```bash
chmod +x ./inst-config-update.sh

./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "$NEW_INSTANCE_CONFIG_ID" \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --all-attached-backends \
  --steady-size 1 \
  --surge-by 1 \
  --drain-seconds 120 \
  --healthy-consecutive-checks 2 \
  --reset-rollout-state
```

Change `--steady-size` to your desired final pool target size.

For example:

```text
Current desired pool size: 3
Surge by: 1
Temporary rollout size: 4
Final pool size after each old VM is removed: 3
```

Use:

```bash
--steady-size 3 --surge-by 1
```

---

## Single-backend rollout

Use this when you do not want automatic discovery and want to target one specific backend set/port.

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "$NEW_INSTANCE_CONFIG_ID" \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --lb-id "$LB_ID" \
  --backend-set-name "<backend-set-name>" \
  --app-port 8080 \
  --steady-size 1 \
  --surge-by 1 \
  --drain-seconds 120 \
  --healthy-consecutive-checks 2 \
  --reset-rollout-state
```

Prefer `--all-attached-backends` if the pool has multiple load balancer attachments.

---

## Targeted recovery for one old VM

Use targeted mode when a previous run already created a replacement VM or when you only want to replace one known old pool member.

```bash
export OLD_INSTANCE_ID="ocid1.instance.oc1.<region>.<unique_id>"

./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "$NEW_INSTANCE_CONFIG_ID" \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --all-attached-backends \
  --target-instance-id "$OLD_INSTANCE_ID" \
  --steady-size 1 \
  --surge-by 1 \
  --drain-seconds 120 \
  --healthy-consecutive-checks 2 \
  --reset-rollout-state
```

Use `--steady-size 1` only if the intended final pool size is actually `1`.

If a previous failed run left the pool already surged, `--steady-size` is important. Without it, the script may treat the current surged pool size as the new desired normal size.

---

## Cleanup stale load balancer backends only

Use cleanup-only mode when the load balancer has backend entries for VMs that no longer exist or are no longer valid running pool members.

> Only use this mode if the selected backend sets are dedicated to this instance pool. If the backend sets contain manually added non-pool backends, this command may delete them.

```bash
./inst-config-update.sh \
  --cleanup-stale-backends-only \
  --delete-orphan-backends true \
  --no-env-file \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --all-attached-backends
```

What cleanup-only does:

```text
1. Discover selected backend sets.
2. Build the list of valid RUNNING pool-member private IPs.
3. List backends on the selected backend sets.
4. Delete backend entries whose IP does not belong to a valid RUNNING pool member.
```

It does not update the instance pool or replace VMs.

---

## Using an env file

The script can run without an env file:

```bash
--no-env-file
```

Or you can provide one:

```bash
--env-file ./rollout.env
```

Example `rollout.env`:

```bash
export NEW_INSTANCE_CONFIG_ID="ocid1.instanceconfiguration.oc1.<region>.<unique_id>"
export COMPARTMENT_ID="ocid1.compartment.oc1..<unique_id>"
export INSTANCE_POOL_ID="ocid1.instancepool.oc1.<region>.<unique_id>"
```

Then run:

```bash
./inst-config-update.sh \
  --env-file ./rollout.env \
  --all-attached-backends \
  --steady-size 1 \
  --surge-by 1 \
  --reset-rollout-state
```

Do not commit real env files to GitHub.

---

## Rollout state and resume behavior

The script stores rollout state in:

```text
./rolling-replace-state
```

You can override it:

```bash
--rollout-state-dir ./my-rollout-state
```

State files include:

```text
lb-attachments.tsv
old-targets.tsv
done-instance-ids.txt
summary.log
before-<instance-id>.ids
after-<instance-id>.ids
replacement-<instance-id>.ids
```

### Start a fresh rollout

Use:

```bash
--reset-rollout-state
```

This deletes and recreates the rollout state directory, then captures the current rollout targets.

### Resume an interrupted rollout

Do not use `--reset-rollout-state` when resuming, unless you intentionally want to recapture targets.

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "$NEW_INSTANCE_CONFIG_ID" \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --all-attached-backends \
  --steady-size 1
```

The script skips instances already listed in:

```text
done-instance-ids.txt
```

---

## Argument reference

| Argument | Required | Description |
|---|---:|---|
| `--new-instance-config-id OCID` | Rollout only | New instance configuration to attach to the pool. |
| `--compartment-id OCID` | Yes | Compartment containing the instance pool instances. |
| `--instance-pool-id OCID` | Yes | Instance pool to update and roll. |
| `--all-attached-backends` | Backend selection | Discover all `ATTACHED` load balancer backend sets from the pool. |
| `--lb-id OCID` | Backend selection | Load balancer OCID for single-backend mode. |
| `--backend-set-name NAME` | Backend selection | Backend set name for single-backend mode. |
| `--app-port PORT` | Backend selection | Backend port for single-backend mode. |
| `--steady-size N` | Recommended | Desired final pool target size. Strongly recommended for recovery. |
| `--surge-by N` | No | Extra capacity to add before removing each old VM. Default: `1`. |
| `--drain-seconds N` | No | Seconds to wait after draining old backends. Default: `120`. |
| `--healthy-consecutive-checks N` | No | Number of consecutive OK checks required for the explicit replacement VM. Default: `2`. |
| `--replacement-timeout-seconds N` | No | Max seconds to wait for replacement health. Default: `1800`. |
| `--poll-seconds N` | No | Poll interval. Default: `15`. |
| `--target-instance-id OCID` | No | Replace only a specific old pool member. Can be repeated. |
| `--reset-rollout-state` | No | Start a fresh rollout and recapture targets. |
| `--rollout-state-dir DIR` | No | Local state directory. Default: `./rolling-replace-state`. |
| `--cleanup-stale-backends-only` | No | Only delete orphan LB backend entries. Does not roll instances. |
| `--delete-orphan-backends true` | Cleanup only | Required safety flag for cleanup-only deletion. |
| `--force-replace-current-config true` | No | Also replace instances already created from the new instance config. Default: `false`. |
| `--preserve-boot-volume true` | No | Preserve old VM boot volumes when terminating. Default: `false`. |
| `--no-env-file` | No | Do not load variables from an env file. |
| `--env-file FILE` | No | Load variables from a shell env file. |
| `--version` | No | Print the script version. |
| `--help` | No | Print built-in usage help. |

---

## Unsupported options

The v13 script intentionally refuses detach mode:

```bash
--replacement-method detach
```

It exits with an error because this version is specifically designed to avoid the OCI `detachInstance` API path.

These values are accepted only as no-detach/direct-terminate aliases:

```bash
--replacement-method terminate
--replacement-method direct-terminate
--replacement-method no-detach
```

You usually do not need to pass `--replacement-method` at all.

---

## How the replacement health gate works

The script does not rely only on total backend count or backend-set health.

For each old VM:

```text
1. Save valid RUNNING pool instance IDs before surge.
2. Scale the pool to N + surge.
3. Save valid RUNNING pool instance IDs after surge.
4. Compute the new replacement instance IDs using before/after diff.
5. If the diff is empty, fall back to RUNNING instances created from the new instance config that are not old targets.
6. For those explicit replacement candidates, check every selected backend set.
7. Require status OK, drain=false, offline=false for all selected backends.
8. Require that condition for --healthy-consecutive-checks cycles.
9. Only then drain the old backend.
```

This prevents the script from draining a healthy old VM just because another unrelated backend is healthy.

---

## Typical output

Successful replacement looks similar to this:

```text
Rollout summary:
  script version:       2026-06-17-v13-no-detach-controller
  steady size:          1
  surge target size:    2
  replacement method:   direct compute terminate; detachInstance is never called

Updating pool to new instance configuration...

Replacing old instance: ocid1.instance.oc1.<region>.<old-id> private_ip=<old-private-ip>
Scaling pool target size from 1 to 2...
Waiting for at least 2 valid RUNNING pool instance(s)...
Explicit replacement candidate ID(s) for this cycle:
  ocid1.instance.oc1.<region>.<new-id>
Waiting for explicit replacement VM backend health...
  explicit replacement readiness: total=1 ready=1 bad=0 consecutive_ok=2/2
Explicit replacement backend readiness passed.
Replacement is healthy. Old target may be degraded; draining it now if backend exists.
Waiting 120s for existing connections to drain...
Directly terminating old pool member...
Restoring pool target size to steady size 1 after direct termination request...
Deleting old backend entries from all selected backend sets...
Verifying replacement candidate(s) still healthy after old removal...
Completed replacement for ocid1.instance.oc1.<region>.<old-id>
```

---

## Troubleshooting

### New VM is `Critical - Connection failed`

The script should refuse to drain/remove the old VM until the explicit replacement backend is `OK`.

Check the new VM directly:

```bash
curl -i --connect-timeout 3 "http://<new-private-ip>:<port>/health"
```

Check backend health:

```bash
oci lb backend-health get \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "<backend-set-name>" \
  --backend-name "<new-private-ip>:<port>"
```

Common causes:

```text
Application is not running on the new VM
Wrong backend port
Wrong health check path
NSG/security list blocks LB-to-backend traffic
New instance configuration lost metadata/user_data
New image does not contain the app/service
Cloud-init failed
Local firewall blocks the backend port
```

### Old VM was already `Critical` or drained

That is allowed. The script treats old targets as replaceable even if they are already degraded.

The safety check is on the replacement VM, not the old VM.

### Pool target size is wrong after a failed run

Always provide the desired final size:

```bash
--steady-size N
```

Example:

```bash
--steady-size 1
```

This prevents a previously surged pool from being treated as the new normal size.

### Script says there are no rollout targets

This usually means all valid RUNNING pool members already have:

```text
instance-configuration-id == NEW_INSTANCE_CONFIG_ID
```

To replace them anyway:

```bash
--force-replace-current-config true
```

Use this only when you intentionally want to recycle instances even though they already use the requested config.

### Stale terminated instances still show in the pool

Because the script does not use `detachInstance`, OCI may show historical or stale terminated pool-member records. The script filters those out by checking the real Compute instance state and VNIC state.

Check active valid pool members manually:

```bash
for id in $(oci compute-management instance-pool list-instances \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --all \
  --query 'data[].id' \
  --raw-output); do
  state=$(oci compute instance get \
    --instance-id "$id" \
    --query 'data."lifecycle-state"' \
    --raw-output 2>/dev/null || echo NOT_FOUND)
  echo "$id $state"
done
```

If stale entries persist and affect operations, open an OCI Support Request.

### Load balancer still shows stale backends

Run cleanup-only mode:

```bash
./inst-config-update.sh \
  --cleanup-stale-backends-only \
  --delete-orphan-backends true \
  --no-env-file \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --all-attached-backends
```

Only use this if the selected backend sets are dedicated to the instance pool.

### The script takes a long time

The script waits for real replacement health before removing old capacity. Long runs are usually caused by:

```text
Replacement VM takes a long time to boot
Application takes a long time to become ready
Health checks are slow or failing
Capacity is not immediately available
Pool or LB has stale records from earlier failed rollouts
High drain duration
```

Tune these values if appropriate:

```bash
--poll-seconds 10
--replacement-timeout-seconds 1200
--healthy-consecutive-checks 2
--drain-seconds 60
```

Do not reduce drain time below what your application traffic pattern can safely tolerate.

---

## IAM permissions

The user or dynamic group running the script needs enough permissions to:

```text
Read and update instance pools
Read instance configurations
List and get compute instances
Terminate compute instances
List VNIC attachments
Read VNICs
Read load balancers and backend sets
Update load balancer backends
Delete load balancer backends
```

The exact policy statements depend on your compartment layout and security model.

---

## Operational checklist

Before running:

```text
Confirm the new instance configuration launches a working VM.
Confirm the new VM has the correct NSGs/security lists.
Confirm the app listens on the backend port.
Confirm the LB health check path/port/protocol are correct.
Confirm pool max capacity and service limits allow steady size + surge.
Confirm backend sets are dedicated to this pool before using cleanup-only mode.
Decide the correct --steady-size.
Back up or preserve boot volumes if needed.
Disable or account for autoscaling policies that may fight manual pool-size changes.
```

After running:

```bash
oci compute-management instance-pool get \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --query 'data.{name:"display-name",size:size,state:"lifecycle-state",config:"instance-configuration-id"}' \
  --output table
```

Check load balancer backends:

```bash
oci lb backend list \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "<backend-set-name>" \
  --all \
  --output table
```

---

## OCI documentation references

- Updating the instance configuration for an instance pool: https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/updatinginstancepool-updating-instance-configuration.htm
- Creating instance pools: https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/creatinginstancepool.htm
- Attaching a load balancer to an instance pool: https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute-management/instance-pool/attach-lb.html
- Editing load balancer backends and drain behavior: https://docs.oracle.com/en-us/iaas/Content/Balance/Tasks/update_backend_server.htm
- Terminating compute instances: https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/instance/terminate.html

---

```markdown
## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
```
