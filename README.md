# OCI Instance Pool Rolling Instance Configuration Update

`inst-config-update.sh` performs a guarded rolling replacement of Compute instances in an Oracle Cloud Infrastructure (OCI) instance pool that is attached to an OCI Load Balancer.

Use it when you have created a new OCI instance configuration, such as one with a new image OCID or updated cloud-init metadata, and you want the pool to move from the old VMs to new VMs with minimal or no application downtime.

The script does **not** patch or mutate running instances. OCI instance pools use an instance configuration as the template for newly created instances. Existing instances are not automatically rebuilt just because the pool points to a new instance configuration. This script automates the replacement process safely around load balancer health checks.

## What the script does

At a high level, the script:

1. Validates that the new instance configuration exists.
2. Captures the current pool members as the old VMs to replace.
3. Checks that the load balancer backend set is healthy before starting.
4. Updates the instance pool to use the new instance configuration.
5. For each old VM:
   1. Temporarily increases the pool target size by `--surge-by`.
   2. Waits for the new VM to appear in the pool.
   3. Waits for the new backend to register on the load balancer.
   4. Waits for the backend set health to become `OK`.
   5. Drains the old backend so it receives no new load balancer traffic.
   6. Waits `--drain-seconds` for in-flight requests to finish.
   7. Removes the old VM.
   8. Restores the pool target size to the original steady-state size.
   9. Verifies pool and load balancer health before continuing.
6. Saves local rollout state so a failed or interrupted rollout can be resumed.

Example flow for a pool of size `2` with `--surge-by 1`:

```text
Start:     old-vm-1, old-vm-2
Scale up:  old-vm-1, old-vm-2, new-vm-1
Drain:     old-vm-1
Remove:    old-vm-1
Back to:   old-vm-2, new-vm-1

Scale up:  old-vm-2, new-vm-1, new-vm-2
Drain:     old-vm-2
Remove:    old-vm-2
End:       new-vm-1, new-vm-2
```

## What this script is for

This script is intended for:

- Rolling an instance pool from one instance configuration to another.
- Replacing VMs after changing the source image, user data, shape, metadata, NSG assignment, or other instance configuration details.
- Pool-backed applications that are already behind an OCI Load Balancer backend set.
- Reducing downtime risk by adding replacement capacity before removing old capacity.

## What this script is not for

This script is not:

- A general deployment framework.
- A blue/green traffic-shifting tool.
- A patch manager for running instances.
- A replacement for health checks, application readiness probes, backups, or change-management controls.
- Designed for OCI Network Load Balancer (`oci nlb`). This script uses the regular OCI Load Balancer CLI namespace, `oci lb`.

## Important safety notes

Read these before using the script in production.

### The script terminates old instances by default

The default replacement method is:

```bash
--replacement-method terminate
```

That means the script eventually calls:

```bash
oci compute instance terminate --preserve-boot-volume false
```

This deletes the old Compute instance and does not preserve its boot volume. Do not use this script against stateful VMs unless your data is stored outside the instance boot volume or is backed up.

### The script attempts zero or near-zero downtime, but cannot guarantee it

The script avoids intentional capacity drops by using a surge-first rollout. Downtime can still occur if:

- The new instance configuration launches broken VMs.
- The application does not start or does not listen on the configured backend port.
- Load balancer health checks do not represent real application readiness.
- Security lists, NSGs, route tables, or host firewalls block LB-to-backend traffic.
- The application stores session state locally and cannot tolerate backend replacement.
- Surge capacity is unavailable because of quotas, capacity limits, or autoscaling bounds.
- The drain window is shorter than your longest active request.

### Do not run multiple rollouts against the same pool at the same time

The script maintains local state in a rollout state directory. Running multiple copies at the same time against the same pool can cause confusing state and unexpected scaling.

### Be careful with autoscaling

If OCI autoscaling policies or external automation are also changing the instance pool size, they can conflict with the script's temporary surge and restore operations. Consider pausing external scaling automation or running during a controlled maintenance window.

## Prerequisites

You need:

- Bash.
- OCI CLI installed and configured.
- `jq` installed.
- A target OCI instance pool.
- A regular OCI Load Balancer attached to the instance pool.
- A backend set associated with the pool.
- A new OCI instance configuration that is known to launch healthy replacement VMs.
- Enough quota and regional capacity to temporarily scale the pool up by `--surge-by`.
- IAM permissions to read and update instance pools, read instance configurations, list pool instances, inspect VNICs, update load balancer backends, and terminate instances.

Check dependencies:

```bash
oci --version
jq --version
bash --version
```

## Required OCI setup

Before running the script, confirm the pool is already attached to the load balancer backend set.

The backend set must use the same backend port you pass with `--app-port`.

For example, if the application listens on port `8080`, the pool's load balancer attachment and the backend set should also point to port `8080`:

```bash
--app-port 8080
```

The load balancer listener port can be different. For example, the load balancer might listen publicly on port `80` and forward to backend port `8080`.

## Required new instance configuration checks

Before using a new instance configuration, verify that it preserves all configuration required for the VM to become healthy behind the load balancer.

Common requirements:

- Correct image OCID.
- Correct subnet and VNIC settings.
- Correct NSGs or security lists allowing LB-to-backend traffic.
- Correct cloud-init or metadata if the application is bootstrapped at first boot.
- Correct backend application port.
- Correct hostname/private DNS settings if the pool uses hostname formatting.
- The app starts automatically and returns a healthy response on the LB health check path.

A very common failure mode is that a manually duplicated instance configuration loses `metadata.user_data` or VNIC NSGs. The replacement instance then boots, but the LB health check fails with connection errors.

## Quick start

Download or copy the script:

```bash
chmod +x inst-config-update.sh
```

Run with all values passed on the command line:

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.<unique_id>" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --lb-id "ocid1.loadbalancer.oc1.<region>.<unique_id>" \
  --backend-set-name "my-backend-set" \
  --app-port 8080 \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method terminate \
  --reset-rollout-state
```

## Command-line arguments

### Required arguments

| Argument | Environment variable | Description |
|---|---|---|
| `--new-instance-config-id` | `NEW_INSTANCE_CONFIG_ID` | OCID of the new instance configuration that the pool should use for newly created VMs. Can also be passed as the first positional argument. |
| `--compartment-id` | `COMPARTMENT_ID` | OCID of the compartment containing the instance pool instances. Used to list pool members and find VNIC attachments. |
| `--instance-pool-id`, `--pool-id` | `INSTANCE_POOL_ID`, `POOL_ID` | OCID of the instance pool to update and roll. |
| `--lb-id`, `--load-balancer-id` | `LB_ID` | OCID of the regular OCI Load Balancer attached to the instance pool. |
| `--backend-set-name` | `BACKEND_SET_NAME` | Name of the LB backend set where pool instances are registered. |
| `--app-port`, `--backend-port` | `APP_PORT`, `BACKEND_PORT` | Backend application port on the instances. The script builds backend names as `private_ip:APP_PORT`. |

### Optional arguments

| Argument | Default | Description |
|---|---:|---|
| `--no-env-file` | enabled | Do not load an env file. Use CLI flags and exported environment variables only. |
| `--env-file <path>` | none | Source variables from a file before parsing CLI flags. CLI flags override env-file values. |
| `--target-pool-size <N>` | current pool target size | Steady-state pool size to return to after each old VM is removed. |
| `--surge-by <N>` | `1` | Extra temporary instances to add before removing each old VM. Usually `1`. |
| `--drain-seconds <N>` | `120` | Seconds to wait after marking the old backend as drained and before removing the old VM. |
| `--health-wait-attempts <N>` | `80` | Number of polling attempts while waiting for pool count, backend count, and backend-set health. Each poll waits 15 seconds. |
| `--oci-max-retries <N>` | `8` | Passed to OCI CLI commands that support `--max-retries`. |
| `--replacement-method terminate` | `terminate` | Terminate old pool members directly, then restore pool target size. This avoids the instance-pool detach API path. |
| `--replacement-method detach` | `terminate` | Use `oci compute-management instance-pool-instance detach --is-auto-terminate true --is-decrement-size true`. Kept for compatibility. |
| `--reset-rollout-state` | false | Delete previous local rollout state and capture the currently attached pool instances as the old VMs to replace. |
| `--rollout-state-dir <path>` | `<workdir>/rolling-replace-state` | Directory used for resumable rollout state. |
| `--workdir <path>` | script directory | Base directory for rollout state when `--rollout-state-dir` is not set. |
| `--delete-stale-backend true` | `true` | Remove an old backend entry from the LB if it remains after the VM is terminated. |
| `--delete-stale-backend false` | `true` | Leave old backend entries alone. |
| `--lb-ip <ip>` | none | Optional. Only used to print a sample final `curl` command. |
| `--listener-port <port>` | none | Optional. Only used to print a sample final `curl` command. |
| `--help`, `-h` | n/a | Print built-in script help. |

### Advanced environment-only tunables

These can be exported before running the script. They do not currently have CLI flags:

| Variable | Default | Description |
|---|---:|---|
| `DETACH_ATTEMPTS` | `5` | Retry attempts for the optional detach replacement method. |
| `TERMINATE_ATTEMPTS` | `5` | Retry attempts for direct instance termination. |
| `SCALE_UPDATE_ATTEMPTS` | `8` | Retry attempts for instance pool size updates. |

Example:

```bash
export TERMINATE_ATTEMPTS=8
export SCALE_UPDATE_ATTEMPTS=10
./inst-config-update.sh ...
```

## CLI-only usage

This is the recommended public example because it avoids relying on a local `outputs.env` file:

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.<unique_id>" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --lb-id "ocid1.loadbalancer.oc1.<region>.<unique_id>" \
  --backend-set-name "my-backend-set" \
  --app-port 8080 \
  --reset-rollout-state
```

## Env-file usage

Env-file support is optional and opt-in.

Create a local file, for example `rollout.env`:

```bash
NEW_INSTANCE_CONFIG_ID="ocid1.instanceconfiguration.oc1.<region>.<unique_id>"
COMPARTMENT_ID="ocid1.compartment.oc1..<unique_id>"
INSTANCE_POOL_ID="ocid1.instancepool.oc1.<region>.<unique_id>"
LB_ID="ocid1.loadbalancer.oc1.<region>.<unique_id>"
BACKEND_SET_NAME="my-backend-set"
APP_PORT="8080"
SURGE_BY="1"
DRAIN_SECONDS="120"
REPLACEMENT_METHOD="terminate"
```

Run:

```bash
./inst-config-update.sh --env-file ./rollout.env --reset-rollout-state
```

Do not commit real env files to a public GitHub repository. Add them to `.gitignore`:

```gitignore
*.env
outputs.env
rolling-replace-state/
```

## Resume behavior

The script stores rollout state in:

```text
<workdir>/rolling-replace-state
```

By default, `<workdir>` is the directory containing the script.

State files include:

```text
old-instance-ids.txt
done-instance-ids.txt
steady-size.txt
new-instance-config-id.txt
```

The script captures the old VM list once, then replaces only those captured instance IDs.

### Starting a new rollout

Use `--reset-rollout-state` when starting a fresh rollout:

```bash
./inst-config-update.sh ... --reset-rollout-state
```

This deletes the previous state and captures the current pool members as the old VMs to replace.

### Resuming a failed or interrupted rollout

Do **not** use `--reset-rollout-state` when resuming the same rollout.

Run the same command again without the reset flag:

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.<unique_id>" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --lb-id "ocid1.loadbalancer.oc1.<region>.<unique_id>" \
  --backend-set-name "my-backend-set" \
  --app-port 8080
```

The script will skip completed instance IDs and continue with remaining old VMs.

### Running the script a second time after success

If the first rollout completed successfully and you run again with `--reset-rollout-state`, the script will treat the current VMs as the new rollout targets.

That is correct if you are rolling from `config-v2` to `config-v3`.

It is unnecessary churn if you pass the same instance configuration again.

## Replacement methods

### Default: `terminate`

The default mode is:

```bash
--replacement-method terminate
```

In this mode, the script:

1. Surges the pool from `N` to `N + SURGE_BY`.
2. Waits for the new backend to be healthy.
3. Drains the old backend.
4. Terminates the old instance directly with `oci compute instance terminate`.
5. Immediately sets the pool target size back to `N`.

This mode avoids the `detachInstance` Compute Management API path.

### Optional: `detach`

You can opt into the instance-pool detach behavior:

```bash
--replacement-method detach
```

In this mode, the script uses:

```bash
oci compute-management instance-pool-instance detach \
  --is-auto-terminate true \
  --is-decrement-size true
```

Only use this if you specifically want the detach behavior. The `terminate` method is the safer default in this repository because it avoids a failure mode where the detach API may return a transient service-side error.

## How the script avoids downtime

The core safety pattern is:

```text
Scale out first -> wait for new backend healthy -> drain old backend -> remove old VM -> return to original size
```

The old backend is not removed until the load balancer backend set is `OK` after the surge.

The script stops instead of continuing if the backend set does not become healthy.

## Health checks

The script checks backend-set health with:

```bash
oci lb backend-set-health get \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME"
```

It expects the backend set status to become:

```text
OK
```

If the status remains `Warning`, `Critical`, `Incomplete`, `Pending`, or unknown, the script aborts before removing more VMs.

## Backend naming

OCI LB backend names are typically in this format:

```text
<private-ip>:<backend-port>
```

The script finds each old instance's primary VNIC private IP, then combines it with `--app-port`:

```text
10.0.*.*:8080
```

That backend is drained before the old instance is removed.

## Stale backend cleanup

By default:

```bash
--delete-stale-backend true
```

After terminating an old instance, the script waits briefly for the load balancer backend entry to disappear. If it remains, the script attempts to remove that stale backend entry.

Disable this behavior with:

```bash
--delete-stale-backend false
```

## Pre-flight checks

Before running the script, consider checking these manually.

### Confirm current pool size

```bash
oci compute-management instance-pool get \
  --instance-pool-id "$INSTANCE_POOL_ID" \
  --query 'data.size' \
  --raw-output
```

### Confirm backend-set health

```bash
oci lb backend-set-health get \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME"
```

### List registered backends

```bash
oci lb backend list \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME" \
  --all \
  --output table
```

### Confirm the new instance configuration exists

```bash
oci compute-management instance-configuration get \
  --instance-configuration-id "$NEW_INSTANCE_CONFIG_ID" \
  --query 'data.{name:"display-name",id:id}' \
  --output table
```

### Confirm there is enough surge capacity

For a pool with target size `N` and `--surge-by 1`, OCI must be able to run `N+1` instances temporarily.

Check service limits, quotas, availability domain capacity, fault domain rules, shape capacity, and subnet IP availability.

## Troubleshooting

### Backend health is `Critical - Connection failed`

This usually means the load balancer cannot connect to the application port on the new VM.

Common causes:

- New instance configuration lost the backend NSG.
- Security list or NSG rules do not allow traffic from the LB to the backend port.
- The app is not running.
- The app is listening on a different port.
- Cloud-init/user data failed.
- The health check path or protocol is wrong.
- Host firewall blocks the port.

Useful checks:

```bash
oci lb backend-set-health get \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME"

oci lb backend list \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME" \
  --all \
  --output table
```

On the VM, check:

```bash
sudo systemctl status <your-service> --no-pager
sudo journalctl -u <your-service> -n 100 --no-pager
sudo cloud-init status --long
sudo tail -n 200 /var/log/cloud-init-output.log
sudo ss -lntp
curl -i http://127.0.0.1:<app-port>/<health-path>
```

### The script says the backend set did not become OK

The script intentionally stops to avoid removing healthy old capacity while replacement capacity is bad.

Fix the new instance configuration, network rules, or application startup problem, then resume the same rollout without `--reset-rollout-state`.

### The script was interrupted

Rerun the same command without `--reset-rollout-state`.

The script should skip completed old instance IDs and continue.

### The script says rollout state was created for another config

This is a safety check. It prevents accidentally resuming a rollout with a different new instance configuration.

For a fresh rollout to a different config, use:

```bash
--reset-rollout-state
```

For a resume, use the same `--new-instance-config-id` as the original run.

### The final pool size is wrong

The script checks the final target size and attempts to restore it to the captured steady size. If external autoscaling or a concurrent operator changes the pool during the rollout, manually inspect the pool before continuing.

### The old backend remains on the load balancer

If `--delete-stale-backend true` is enabled, the script attempts cleanup automatically. You can also remove it manually:

```bash
oci lb backend delete \
  --load-balancer-id "$LB_ID" \
  --backend-set-name "$BACKEND_SET_NAME" \
  --backend-name "10.0.*.*:8080" \
  --force
```

## Example: rolling from config v1 to config v2

Assume the pool is currently running instances created from `config-v1`, and you created a new instance configuration named `config-v2`.

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.configv2" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --lb-id "ocid1.loadbalancer.oc1.<region>.<unique_id>" \
  --backend-set-name "my-backend-set" \
  --app-port 8080 \
  --surge-by 1 \
  --drain-seconds 120 \
  --replacement-method terminate \
  --reset-rollout-state
```

After the rollout completes, all original pool instances should have been replaced by instances launched from `config-v2`.

## Example: resume after a failure

Do not reset state:

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.configv2" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --lb-id "ocid1.loadbalancer.oc1.<region>.<unique_id>" \
  --backend-set-name "my-backend-set" \
  --app-port 8080
```

## Example: new rollout from config v2 to config v3

Use reset state because this is a new rollout:

```bash
./inst-config-update.sh \
  --no-env-file \
  --new-instance-config-id "ocid1.instanceconfiguration.oc1.<region>.configv3" \
  --compartment-id "ocid1.compartment.oc1..<unique_id>" \
  --instance-pool-id "ocid1.instancepool.oc1.<region>.<unique_id>" \
  --lb-id "ocid1.loadbalancer.oc1.<region>.<unique_id>" \
  --backend-set-name "my-backend-set" \
  --app-port 8080 \
  --reset-rollout-state
```

## Public GitHub guidance

For a public repository:

- Do not commit real OCIDs if your organization treats them as sensitive.
- Do not commit private keys, OCI config files, API keys, or session tokens.
- Do not commit `outputs.env`, `rollout.env`, or generated state directories.
- Use placeholders in examples.
- Add local env/state files to `.gitignore`.

Suggested `.gitignore` entries:

```gitignore
*.env
outputs.env
rollout.env
rolling-replace-state/
*.log
.oci/
```

## Limitations

- Supports regular OCI Load Balancer via `oci lb`; it does not support Network Load Balancer via `oci nlb`.
- Assumes the backend name can be resolved from the instance primary VNIC private IP plus `APP_PORT`.
- Assumes the pool's LB attachment automatically registers pool members in the specified backend set.
- Does not create the new instance configuration.
- Does not validate application-level correctness beyond LB backend-set health.
- Does not manage DNS traffic shifting.
- Does not manage autoscaling policies.
- Does not preserve boot volumes in default terminate mode.

## References

- OCI: Updating the instance configuration for an instance pool  
  https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/updatinginstancepool-updating-instance-configuration.htm

- OCI: Updating instance pool size  
  https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/updatinginstancepool_topic-update-instance-pool-size.htm

- OCI: Creating instance pools and attaching load balancers  
  https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/creatinginstancepool.htm

- OCI CLI: Instance pool update  
  https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute-management/instance-pool/update.html

- OCI CLI: Load balancer backend update / drain  
  https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/lb/backend/update.html

- OCI: Load balancer backend set health  
  https://docs.oracle.com/en-us/iaas/Content/Balance/Tasks/get_backend-set-health.htm

- OCI CLI: Compute instance terminate  
  https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/instance/terminate.html


## License

This project is licensed under the MIT License. 