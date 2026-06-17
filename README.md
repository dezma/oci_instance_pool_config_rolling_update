# OCI Instance Pool Rolling Instance Configuration Update

`inst-config-update-v4-multi-lb-safe.sh` performs a safe rolling replacement of OCI Compute instance pool members after you point the pool at a new instance configuration.

It is intended for instance pools behind an **OCI Load Balancer**, including pools attached to **multiple backend sets** and backend ports.

The recommended mode is:

```bash
--all-attached-backends --replacement-method detach
```

That mode lets the script read all load balancer attachments from the instance pool and handle every attached backend set/port during drain and cleanup.

---

## What the script does

The script does **not** patch existing VMs in place. Instead, it replaces them safely.

At a high level, it does this:

```text
1. Validate the new instance configuration.
2. Discover load balancer backend attachments.
3. Capture only valid active pool members as the old VMs to replace.
4. Update the instance pool to the new instance configuration.
5. Temporarily scale the pool up by SURGE_BY.
6. Wait for new VMs and load balancer backends to become healthy.
7. Drain the old VM from every selected backend set.
8. Wait for the drain window.
9. Detach and auto-terminate the old VM.
10. Delete old backend entries from every selected backend set.
11. Verify the pool and all selected backend sets are healthy.
12. Repeat until every original VM has been replaced.
```

Example with a pool of size `2` and `--surge-by 1`:

```text
Initial:
  old-vm-1
  old-vm-2

Step 1:
  scale pool to 3
  wait for new-vm-1 healthy
  drain old-vm-1
  detach and terminate old-vm-1
  delete old-vm-1 backend entries
  pool returns to 2

Step 2:
  scale pool to 3
  wait for new-vm-2 healthy
  drain old-vm-2
  detach and terminate old-vm-2
  delete old-vm-2 backend entries
  pool returns to 2

Final:
  new-vm-1
  new-vm-2
```

---

## Why this version exists

This version addresses rollout issues that can happen with OCI instance pools behind load balancers:

| Issue | How this script handles it |
|---|---|
| Pool is attached to multiple backend sets | `--all-attached-backends` discovers every attached backend set and port from the instance pool. |
| Old terminated VMs remain on the LB as `Critical - Connection failed` | Old backend entries are deleted from every selected backend set after drain. |
| Stale pool entries appear in `instance-pool list-instances` | The script captures only instances that still exist in Compute, are active, and have an attached VNIC/private IP. |
| Direct VM termination can leave dirty pool membership | The default is `--replacement-method detach`, which uses the instance-pool detach workflow. |
| Rollout fails halfway | The script keeps rollout state and can resume without recapturing already-completed instances. |
| Existing stale LB backends need cleanup | `--cleanup-stale-backends-only` removes orphaned backend entries without doing a rollout. |

---

## Requirements

Install and configure:

```text
bash
oci CLI
jq
sort
mktemp
```

Check locally:

```bash
oci --version
jq --version
```

Your OCI identity must have permissions to manage or inspect:

```text
Compute instances
Compute instance pools
Instance configurations
VNIC attachments and VNICs
Load balancers, backend sets, and backends
```

---

## Required OCI resources

Before using the script, you need:

```text
1. An existing OCI Compute instance pool.
2. A new instance configuration OCID.
3. One or more OCI Load Balancer backend sets attached to the instance pool.
4. A currently healthy application/backend set state.
5. Enough OCI capacity and limits to temporarily surge the pool.
```

The script does **not** create a new image or instance configuration. Create the new instance configuration first, then pass its OCID to this script.

---

## Important safety notes

### Use cleanup mode only with dedicated backend sets

`--cleanup-stale-backends-only`, `--pre-clean-stale-backends true`, and `--post-clean-stale-backends true` delete backend entries that do not map to active pool members.

That is safe only if the selected backend sets are dedicated to this instance pool.

Do not use broad cleanup if a backend set also contains manually added servers, blue/green targets, shared targets, or non-pool backends that should remain.

### Prefer detach mode

The recommended replacement mode is:

```bash
--replacement-method detach
```

Detach mode uses:

```bash
oci compute-management instance-pool-instance detach \
  --is-auto-terminate true \
  --is-decrement-size true
```

That means:

```text
Detach the old instance from the pool.
Terminate/delete the old instance and boot volume.
Decrease the pool target size after the temporary surge.
```

### Terminate mode is only a workaround

The script supports:

```bash
--replacement-method terminate
```

This directly calls Compute instance termination and then restores the pool target size.

Use it only if the instance-pool detach API is temporarily failing and you understand the tradeoff. Direct termination can leave stale pool membership or stale load balancer backend entries depending on OCI convergence behavior.

### Do not reset state when resuming

Use `--reset-rollout-state` only for a fresh rollout.

Do not use it when resuming a failed or partially completed rollout.

---

## Quick start

### 1. Make the script executable

```bash
chmod +x ./inst-config-update-v4-multi-lb-safe.sh
```

### 2. Optional: clean stale LB backends first

Run this if previous runs left terminated or missing VMs on the load balancer as `Critical - Connection failed`.

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --cleanup-stale-backends-only \
  --no-env-file \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --all-attached-backends
```

### 3. Run the rolling update

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1..example" \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --all-attached-backends \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method detach \
  --reset-rollout-state
```

---

## Recommended command for multi-backend pools

Use this when the instance pool is attached to multiple backend sets or ports.

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1..example" \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --all-attached-backends \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method detach \
  --reset-rollout-state
```

With `--all-attached-backends`, you do **not** need to pass:

```text
--lb-id
--backend-set-name
--app-port
```

The script reads the pool's load balancer attachments and discovers the load balancer OCID, backend set name, port, and VNIC selection stored on the pool.

---

## Cleanup-only mode

Use cleanup-only mode to remove stale LB backend entries without changing the pool's instance configuration and without replacing VMs.

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --cleanup-stale-backends-only \
  --no-env-file \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --all-attached-backends
```

Cleanup-only mode does this:

```text
1. Discover selected backend sets and ports.
2. Build a list of active private IPs from valid active pool members.
3. Keep backend entries that match active pool private IPs.
4. Delete backend entries that do not match active pool private IPs.
5. Wait for selected backend sets to return to OK.
```

Example using placeholders:

```text
Active pool private IPs:
  <active-private-ip>

Selected backend sets:
  web-backend-set:<web-port>
  api-backend-set:<api-port>

Kept:
  <active-private-ip>:<web-port>
  <active-private-ip>:<api-port>

Deleted:
  <stale-private-ip>:<web-port>
  <stale-private-ip>:<api-port>
```

---

## Single-backend mode

Use this when you intentionally want to handle only one backend set and one backend port.

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1..example" \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --lb-id "ocid1.loadbalancer.oc1..example" \
  --backend-set-name "example-backend-set" \
  --app-port 8080 \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method detach \
  --reset-rollout-state
```

Single-backend mode is compatible with older one-backend workflows, but it will not clean up other backend sets attached to the same pool.

---

## Filter auto-discovered attachments to one load balancer

If the pool has multiple load balancer attachments but you want to handle only one load balancer, combine `--all-attached-backends` with `--lb-id`.

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1..example" \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --lb-id "ocid1.loadbalancer.oc1..example" \
  --all-attached-backends \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method detach \
  --reset-rollout-state
```

---

## Resume a failed rollout

If a rollout stops halfway, rerun the script **without** `--reset-rollout-state`.

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1..example" \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --all-attached-backends \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method detach
```

The script will reuse the existing rollout state directory and skip instances already marked as completed.

---

## Start a fresh rollout

Use `--reset-rollout-state` when starting a new rollout.

Examples:

```text
config-v1 -> config-v2: use --reset-rollout-state
config-v2 -> config-v3: use --reset-rollout-state
resume failed config-v1 -> config-v2: do not use --reset-rollout-state
rerun same completed rollout: do not use --reset-rollout-state unless you intentionally want to recycle again
```

---

## Optional environment file usage

The default behavior is `--no-env-file`. You can optionally use an env file.

Example `rollout.env`:

```bash
NEW_INSTANCE_CONFIG_ID="ocid1.instanceconfiguration.oc1..example"
COMPARTMENT_ID="ocid1.compartment.oc1..example"
INSTANCE_POOL_ID="ocid1.instancepool.oc1..example"
```

Run:

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --env-file ./rollout.env \
  --all-attached-backends \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method detach \
  --reset-rollout-state
```

---

## Arguments

### Required for rollout

| Argument | Required | Description |
|---|---:|---|
| `--new-instance-config-id <ocid>` | Yes | New instance configuration OCID to apply to the pool. Replacement VMs are created from this configuration. |
| `--compartment-id <ocid>` | Yes | Compartment OCID used to list pool instances and VNIC attachments. |
| `--instance-pool-id <ocid>` | Yes | Instance pool OCID to update and roll. |

### Required for cleanup-only mode

| Argument | Required | Description |
|---|---:|---|
| `--cleanup-stale-backends-only` | Yes | Runs stale backend cleanup without changing the instance configuration or replacing VMs. |
| `--compartment-id <ocid>` | Yes | Compartment OCID used to list active pool instances and VNICs. |
| `--instance-pool-id <ocid>` | Yes | Instance pool whose active members are used as the source of truth. |
| `--all-attached-backends` or single-backend arguments | Yes | Selects which backend sets to inspect and clean. |

### Load balancer selection

| Argument | Description |
|---|---|
| `--all-attached-backends` | Recommended. Reads all `ATTACHED` load balancer attachments from the instance pool and handles every discovered backend set and port. |
| `--lb-id <ocid>` | In single-backend mode, this is the load balancer OCID. With `--all-attached-backends`, this filters discovered attachments to one load balancer. |
| `--backend-set-name <name>` | Backend set name for single-backend mode. Use with `--app-port`. |
| `--app-port <port>` | Backend port for single-backend mode. Use with `--backend-set-name`. |

### Rollout behavior

| Argument | Default | Description |
|---|---:|---|
| `--surge-by <n>` | `1` | Temporary extra pool capacity during replacement. Example: pool size `2`, surge-by `1` means temporary target size `3`. |
| `--drain-seconds <seconds>` | `120` | How long to wait after marking old backends drained before removing the old VM. |
| `--replacement-method <detach|terminate>` | `detach` | `detach` uses the instance-pool detach API with auto-terminate. `terminate` directly terminates the Compute instance and is only a workaround. |
| `--delete-stale-backend <true|false>` | `true` | Deletes old backend entries after drain and VM removal. |
| `--pre-clean-stale-backends <true|false>` | `false` | Runs broad stale backend cleanup before rollout. Use only with dedicated backend sets. |
| `--post-clean-stale-backends <true|false>` | `false` | Runs broad stale backend cleanup after rollout. Use only with dedicated backend sets. |
| `--health-wait-attempts <n>` | `80` | Number of polling attempts for backend count and health waits. Most wait loops sleep about 15 seconds between attempts. |
| `--oci-max-retries <n>` | `8` | Max retries passed to OCI CLI operations that support retries. |

### State and configuration

| Argument | Default | Description |
|---|---:|---|
| `--reset-rollout-state` | disabled | Starts fresh by deleting the rollout state directory and recapturing current active pool members. |
| `--rollout-state-dir <path>` | `./rolling-replace-state` | Local state directory for captured old IDs, done IDs, cached IPs, selected attachments, and warnings. |
| `--env-file <path>` | none | Sources environment variables from a file before validation. |
| `--no-env-file` | default | Ignores env files and uses CLI arguments/exported variables only. |
| `-h`, `--help` | n/a | Shows script help. |

---

## Rollout state directory

The script stores state in:

```text
./rolling-replace-state
```

The directory may contain:

```text
old-instance-ids.txt
  Original active pool members captured at rollout start.

done-instance-ids.txt
  Instances already replaced.

original-size.txt
  Original pool target size.

lb-attachments.tsv
  Selected load balancer/backend-set/port attachments.

instance-private-ips/
  Cached private IPs for captured instances.

warnings.txt
  Non-fatal warnings recorded during the run.
```
---

## Validation commands before rollout

Set variables first:

```bash
export COMPARTMENT_ID="ocid1.compartment.oc1..example"
export INSTANCE_POOL_ID="ocid1.instancepool.oc1..example"
```

### Check pool size and state

```bash
oci compute-management instance-pool get \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --query 'data.{name:"display-name",size:size,state:"lifecycle-state"}' \
  --output table
```

### List pool instances

```bash
oci compute-management instance-pool list-instances \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --all \
  --query 'data[].{id:id,name:"display-name",state:"lifecycle-state"}' \
  --output table
```

### Inspect load balancer attachments on the pool

```bash
oci compute-management instance-pool get \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --query 'data."load-balancers"[].{lb:"load-balancer-id",backendSet:"backend-set-name",port:port,state:"lifecycle-state",vnic:"vnic-selection"}' \
  --output table
```

### Check a backend set health

```bash
export LB_ID="ocid1.loadbalancer.oc1..example"
export BACKEND_SET_NAME="example-backend-set"

oci lb backend-set-health get \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME"
```

### List backend servers

```bash
oci lb backend list \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME" \
  --all \
  --query 'data[].{name:name,ip:"ip-address",port:port,drain:drain,offline:offline,backup:backup,weight:weight}' \
  --output table
```

---

## Troubleshooting

### Backend shows `Critical - Connection failed`

Common causes:

```text
- The VM was terminated but the backend entry still exists.
- The app is not listening on the expected backend port.
- NSG/security-list rules block LB-to-backend traffic.
- The health-check path or port is wrong.
- The replacement instance did not bootstrap correctly.
```

First run cleanup-only mode:

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --cleanup-stale-backends-only \
  --no-env-file \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --all-attached-backends
```

Then verify backend health again.

### Pool target size is small but many instances appear in the pool list

The script filters stale/non-active records before rollout. You can manually check what Compute sees:

```bash
for id in $(oci compute-management instance-pool list-instances \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --all \
  --query 'data[].id' \
  --raw-output)
do
  state=$(oci compute instance get \
    --instance-id "$id" \
    --query 'data."lifecycle-state"' \
    --raw-output 2>/dev/null || echo "NOT_FOUND")

  echo "$id $state"
done
```

If many entries are `NOT_FOUND`, clean stale LB backends first. If ghost pool records remain, open an OCI support request with the affected instance pool OCID and stale instance OCIDs.

### The script takes a long time

The script waits for several conditions:

```text
- Pool scale-up to complete.
- New VMs to exist and have VNIC/private IPs.
- Backends to register in every selected backend set.
- Every selected backend set to return OK.
- The configured drain window for each old VM.
```

With the default:

```bash
--health-wait-attempts 80
```

most health/count loops can wait up to about:

```text
80 attempts x 15 seconds = 20 minutes
```

Multiple backend sets and repeated health waits can make a rollout long if backends are slow to register or unhealthy.

### Detach fails with OCI `500/InternalError`

The script retries and checks actual state before trying again. If detach keeps failing, it stops and leaves replacement capacity in place instead of continuing unsafely.

Recommended response:

```text
1. Do not rerun with --reset-rollout-state.
2. Check whether the old VM is still attached to the pool.
3. Check backend health.
4. Retry after OCI service state settles, or open an OCI support request with the opc-request-id.
```

### Replacement instance never becomes healthy

Check:

```text
- The new instance configuration uses the expected image.
- The new instance configuration preserved the backend NSG/security rules.
- The app listens on every backend port attached to the pool.
- Health-check paths and ports match the application.
- Cloud-init/user_data completed successfully.
- The app is ready before the health check marks the backend OK.
```

---

## What this script does not do

This script does not:

```text
- Create a custom image.
- Create a new instance configuration.
- Modify NSGs or security lists.
- Modify load balancer listeners or backend-set health-check settings.
- Manage Network Load Balancers.
- Fix OCI service-side ghost pool records that cannot be detached through OCI APIs.
- Guarantee zero downtime if the app or infrastructure is unhealthy.
```

---

## OCI documentation links

- Updating the instance configuration for an instance pool: <https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/updatinginstancepool-updating-instance-configuration.htm>
- OCI CLI instance-pool-instance detach: <https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.53.0/oci_cli_docs/cmdref/compute-management/instance-pool-instance/detach.html>
- OCI CLI instance pool load balancer attachment: <https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.70.0/oci_cli_docs/cmdref/compute-management/instance-pool/attach-lb.html>
- OCI Load Balancer backend commands: <https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/lb/backend.html>

---

## Quick reference

Cleanup stale LB backends:

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --cleanup-stale-backends-only \
  --no-env-file \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --all-attached-backends
```

Run a fresh rolling update:

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1..example" \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --all-attached-backends \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method detach \
  --reset-rollout-state
```

Resume an interrupted rollout:

```bash
./inst-config-update-v4-multi-lb-safe.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1..example" \
  --compartment-id "ocid1.compartment.oc1..example" \
  --instance-pool-id "ocid1.instancepool.oc1..example" \
  --all-attached-backends \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method detach
```
