# lab-rancher-pvc

A wrapper Helm chart around Rancher's official [Local Path Provisioner](https://github.com/rancher/local-path-provisioner) chart (`oci://ghcr.io/rancher/local-path-provisioner/charts`), tailored and hardened for **Talos Linux** clusters enforcing Kubernetes **Pod Security Standards (PSS)** `restricted` profiles.

---

## Overview

Rancher's Local Path Provisioner provides dynamic Persistent Volume (PV) provisioning utilizing local storage on Kubernetes nodes. Standard deployments encounter two critical hurdles on Talos Linux clusters enforcing `restricted` pod security:

1. **Immutable Filesystem Layout**: Talos Linux enforces an immutable, read-only root filesystem (`/`) where the upstream default directory (`/opt/local-path-provisioner`) is ephemeral or unwritable. Talos requires persistent local storage under `/var` (configured to `/var/local/local-path-provisioner` by default).
2. **Pod Security Standards (`restricted`)**: When `restricted` (or `baseline`) Pod Security Admission (PSA) is enforced cluster-wide, Kubernetes rejects the transient **helper pods** spawned by `local-path-provisioner` because they mount node storage via `hostPath` and execute `mkdir`/`rm -rf` as root (`UID 0`).

Rather than maintaining a forked copy of upstream templates, this chart declares the official upstream `local-path-provisioner` OCI chart as a Helm dependency and extends it with:
- Automated creation and labeling of the isolated `local-path-storage` namespace with `pod-security.kubernetes.io/enforce: privileged` (`templates/namespace.yaml`).
- Pre-configured Talos node storage path defaults (`/var/local/local-path-provisioner`).
- Hardened controller `podSecurityContext` and container `securityContext` defaults that strictly satisfy the PSS `restricted` profile (`UID/GID 65534`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`).

---

## Architecture & Security Model

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ Namespace: local-path-storage (PSA: privileged)                              │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ Controller Deployment (Upstream subchart, enforces PSS "restricted")   │  │
│  │  • runAsNonRoot: true (UID/GID 65534)                                  │  │
│  │  • readOnlyRootFilesystem: true                                        │  │
│  │  • allowPrivilegeEscalation: false                                     │  │
│  │  • capabilities.drop: ["ALL"]                                          │  │
│  │  • seccompProfile: RuntimeDefault                                      │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                      │                                        │
│                        Watches PVCs  │  Spawns transient                      │
│                        & Node status │  helper pods                           │
│                                      ▼                                        │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ Ephemeral Helper Pods (mkdir -m 0777 / rm -rf)                         │  │
│  │  • HostPath Volume: /var/local/local-path-provisioner                  │  │
│  │  • Runs as root briefly to create/remove node volume directories       │  │
│  │  • priorityClassName: system-node-critical                             │  │
│  │  • Scoped CPU/memory requests & limits                                 │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                      │                                        │
└──────────────────────────────────────┼───────────────────────────────────────┘
                                       ▼ HostPath mount
┌──────────────────────────────────────────────────────────────────────────────┐
│ Talos Linux Node (Persistent storage at /var/local/local-path-provisioner)   │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Why the Namespace Requires the Privileged PSA Label

Kubernetes Pod Security Admission evaluates pod specifications against standard profiles before admitting them to the API:

- **Restricted & Baseline Profiles**: Strictly prohibit `hostPath` volumes (and `restricted` also prohibits root execution).
- **Helper Pod Requirement**: When a PVC is bound or deleted, `local-path-provisioner` launches a short-lived pod that mounts the node base path via `hostPath` to run `mkdir -m 0777 -p "$VOL_DIR"` or `rm -rf "$VOL_DIR"`. Creating `$VOL_DIR` with `0777` permissions ensures that non-root application pods running in `restricted` workload namespaces can write to their mounted PVCs without permission errors.
- **Solution**: The `local-path-storage` namespace is labeled with `pod-security.kubernetes.io/enforce: privileged`. This isolates elevated storage lifecycle operations to `local-path-storage` while keeping `restricted` enforcement intact across all workload namespaces.

### Controller Pod Hardening (Restricted PSS)

Even though `local-path-storage` permits privileged helper pods, the long-running controller `Deployment` is configured via upstream subchart values to comply with the `restricted` standard:

| Security Dimension | Restricted Standard Requirement | Controller Configuration |
|---|---|---|
| **Non-Root Execution** | `runAsNonRoot: true` | `runAsNonRoot: true`, `runAsUser: 65534`, `runAsGroup: 65534` |
| **Root Filesystem** | Immutable best practice | `readOnlyRootFilesystem: true` |
| **Privilege Escalation** | `allowPrivilegeEscalation: false` | `allowPrivilegeEscalation: false` |
| **Linux Capabilities** | Drop `ALL` | `capabilities.drop: ["ALL"]` |
| **Seccomp Profile** | `RuntimeDefault` or `Localhost` | `seccompProfile: { type: RuntimeDefault }` |
| **Host Namespaces** | Disallow host network/PID/IPC | Private pod namespaces (`hostUsers: true`) |

---

## Talos Linux Node Storage

### Default: Persistent `/var` Partition (`/var/local/local-path-provisioner`)

On Talos Linux, `/var` is backed by the persistent `EPHEMERAL` partition and exposed to the `kubelet`. By setting `local-path-provisioner.nodePathMap` to `/var/local/local-path-provisioner` (the default in this chart), dynamic PV provisioning works out of the box without requiring additional disks or machine configuration patches.

If your Talos setup requires explicit `kubelet` bind-mount propagation for `/var/local/local-path-provisioner`, patch `machine.kubelet.extraMounts`:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/local/local-path-provisioner
        type: bind
        source: /var/local/local-path-provisioner
        options:
          - bind
          - rshared
          - rw
```

### Optional: Dedicated Disk via Talos `UserVolumeConfig`

If you prefer to back local PVs with a dedicated secondary disk using a Talos `UserVolumeConfig` (which mounts under `/var/mnt/<name>`):

1. Apply a `UserVolumeConfig` and expose the mount to `kubelet`:

   ```yaml
   machine:
     kubelet:
       extraMounts:
         - destination: /var/mnt/local-path-provisioner
           type: bind
           source: /var/mnt/local-path-provisioner
           options:
             - bind
             - rshared
             - rw
   ---
   apiVersion: v1alpha1
   kind: UserVolumeConfig
   name: local-path-provisioner
   provisioning:
     diskSelector:
       match: "!system_disk"
     minSize: 100GB
     maxSize: 100GB
   ```

2. Override `nodePathMap` when installing the chart:

   ```yaml
   local-path-provisioner:
     nodePathMap:
       - node: DEFAULT_PATH_FOR_NON_LISTED_NODES
         paths:
           - /var/mnt/local-path-provisioner
   ```

---

## Directory Structure

```text
.
├── .github/
│   └── workflows/
│       ├── lint.yml             # Lints workflows, commits, and shell scripts
│       ├── security.yml         # Scans for secrets and audits workflow security
│       ├── release.yml          # Semantic release and Helm chart publishing to GHCR
│       └── test_release.yml     # PR dry-run test for releases and chart packaging
├── chart/
│   ├── Chart.yaml               # Wrapper chart definition & upstream OCI dependency
│   ├── Chart.lock               # Locked upstream local-path-provisioner chart digest
│   ├── values.yaml              # Namespace PSA settings & upstream subchart overrides
│   ├── .helmignore              # Ignore rules for chart packaging
│   └── templates/
│       ├── _helpers.tpl         # Wrapper chart naming and label helpers
│       └── namespace.yaml       # Namespace manifest with privileged PSA labels
├── hk.pkl                       # hk git hooks and checks configuration
├── mise.toml                    # Mise tools and tasks
└── README.md
```

---

## Quickstart & Deployment

### 1. Tooling Setup

Install the required CLI tools and git hooks:

```sh
mise run install
```

### 2. Build Dependencies, Lint, and Render Chart

Fetch the locked upstream subchart, lint, and render manifests locally:

```sh
# Download upstream chart dependency into chart/charts/
mise run helm-d

# Lint wrapper chart
mise run helm-l

# Render manifests to rendered.yaml
mise run helm-t
```

### 3. Install to Cluster

Deploy the chart to your connected Kubernetes cluster:

```sh
mise run helm-i
# or:
# helm dependency build chart/
# helm install pvc-rancher chart/
```

> **Note:** When `namespace.create` is `true` (default), the chart creates and labels the `local-path-storage` namespace directly—do not pass `--create-namespace` to `helm install`. If `local-path-storage` already exists in your cluster, set `namespace.create=false` and ensure the namespace carries `pod-security.kubernetes.io/enforce=privileged`.

### 4. Verify StorageClass and Controller

```sh
# Verify namespace PSA labels
kubectl get ns local-path-storage --show-labels

# Verify controller pod is running
kubectl get pods -n local-path-storage -l app.kubernetes.io/name=local-path-provisioner

# Verify default StorageClass
kubectl get storageclass local-path
```

---

## Testing PVC Provisioning (Restricted Workload Namespace)

To verify dynamic volume provisioning from a namespace enforcing `restricted` pod security:

### 1. Apply a Test PVC and Restricted Pod

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-local-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-local-pod
  namespace: default
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: writer
      image: docker.io/library/busybox:latest
      command: ["/bin/sh", "-c", "echo 'Hello from Talos!' > /data/message.txt && cat /data/message.txt && sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-local-pvc
```

```sh
kubectl apply -f test-pvc.yaml
```

### 2. Verify Bound Status

Because `volumeBindingMode` is `WaitForFirstConsumer`, the PV is dynamically provisioned on the node where `test-local-pod` is scheduled:

```sh
# Check PVC status
kubectl get pvc test-local-pvc

# Check pod logs
kubectl logs test-local-pod

# Verify provisioner logs
kubectl logs -n local-path-storage -l app.kubernetes.io/name=local-path-provisioner
```

### 3. Cleanup Test Resources

```sh
kubectl delete pod test-local-pod
kubectl delete pvc test-local-pvc
```

---

## Configuration Reference

Key parameters in [`chart/values.yaml`](chart/values.yaml) (any upstream [local-path-provisioner chart value](https://github.com/rancher/local-path-provisioner/blob/v0.0.37/deploy/chart/local-path-provisioner/values.yaml) can be passed under `local-path-provisioner:`):

| Parameter | Description | Default |
|---|---|---|
| `namespace.create` | Create and label the target namespace | `true` |
| `namespace.name` | Target namespace name | `local-path-storage` |
| `namespace.podSecurity.enforce` | Pod Security Admission `enforce` level | `privileged` |
| `local-path-provisioner.namespaceOverride` | Namespace for subchart resources (keep aligned with `namespace.name`) | `local-path-storage` |
| `local-path-provisioner.nodePathMap` | Node path configuration for volume storage | `[{node: DEFAULT_PATH_FOR_NON_LISTED_NODES, paths: [/var/local/local-path-provisioner]}]` |
| `local-path-provisioner.storageClass.create` | Create StorageClass | `true` |
| `local-path-provisioner.storageClass.name` | StorageClass name | `local-path` |
| `local-path-provisioner.storageClass.provisionerName` | Provisioner identifier | `rancher.io/local-path` |
| `local-path-provisioner.storageClass.defaultClass` | Mark as cluster default StorageClass | `true` |
| `local-path-provisioner.storageClass.volumeBindingMode` | Binding mode (`Immediate` or `WaitForFirstConsumer`) | `WaitForFirstConsumer` |
| `local-path-provisioner.storageClass.reclaimPolicy` | Reclaim policy (`Delete` or `Retain`) | `Delete` |
| `local-path-provisioner.podSecurityContext.runAsNonRoot` | Enforce non-root pod execution on controller | `true` |
| `local-path-provisioner.podSecurityContext.runAsUser` | Controller UID | `65534` |
| `local-path-provisioner.securityContext.readOnlyRootFilesystem` | Read-only root filesystem on controller | `true` |
| `local-path-provisioner.securityContext.capabilities.drop` | Dropped capabilities on controller | `["ALL"]` |

---

## Available Mise Tasks

Run tasks using `mise run <task>`:

| Task | Description | Command |
|---|---|---|
| `install` | Install tools and configure git hooks | `hk install --mise` |
| `hk` (or `check`) | Run all project linters and checks | `hk check --all` |
| `helm-d` | Build Helm chart dependencies | `helm dependency build chart/` |
| `helm-l` | Lint Helm chart | `helm lint chart/` |
| `helm-t` | Render templates to `rendered.yaml` | `helm template test chart/ > rendered.yaml` |
| `helm-i` | Install Helm chart to cluster | `helm install test chart/` |
| `helm-u` | Uninstall Helm chart from cluster | `helm uninstall test` |
| `trivy-fs` | Scan filesystem for vulnerabilities | `trivy fs .` |

---

## Conventional Commits & Releases

Commits must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:
- `feat: add new feature` -> Triggers a **minor** release (e.g., `v0.1.0` -> `v0.2.0`).
- `fix: resolve issue` -> Triggers a **patch** release (e.g., `v0.1.0` -> `v0.1.1`).
- `feat!: breaking change` -> Triggers a **major** release.
- `chore:`, `docs:`, `ci:`, `test:`, `refactor:` -> Maintenance changes (no release bump).

Upon merging to `main`, the `release.yml` workflow automatically computes the next version, updates `version` and `appVersion` in `chart/Chart.yaml`, creates a Git tag, publishes a GitHub Release, and packages and pushes the Helm chart to GHCR.

## Support

If you find this project useful, consider supporting my work on [Ko-fi](https://ko-fi.com/joeckr):

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/joeckr)

## License

Please refer to the `LICENSE` file for details.
