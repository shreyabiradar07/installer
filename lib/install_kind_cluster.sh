#!/usr/bin/env bash

################################################################################
# Kind Cluster Setup
#
# Provisions a local Kind cluster with a local container registry.
# Idempotent — safe to run when the cluster is already present.
#
# Exported functions:
#   install_kind_cluster   — creates cluster + registry if absent
#   uninstall_kind_cluster — deletes cluster and registry
################################################################################

# Prevent multiple sourcing
if [[ -n "${INSTALL_KIND_CLUSTER_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly INSTALL_KIND_CLUSTER_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Global variable defaults — safe to source standalone or from other entrypoints
# ---------------------------------------------------------------------------
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
DRY_RUN="${DRY_RUN:-false}"
export SCRIPT_DIR CONTAINER_RUNTIME DRY_RUN

# Kind-specific constants (overridable via env vars before sourcing this file)
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-causa-rca}"
KIND_REGISTRY_NAME="${KIND_REGISTRY_NAME:-causa-rca-registry}"
KIND_REGISTRY_PORT="${KIND_REGISTRY_PORT:-5001}"
export KIND_CLUSTER_NAME KIND_REGISTRY_NAME KIND_REGISTRY_PORT

# ---------------------------------------------------------------------------
# _kind_cluster_exists  — returns 0 if the cluster is already present
# ---------------------------------------------------------------------------
_kind_cluster_exists() {
    # Must target the same provider used to create the cluster, otherwise a
    # podman-backed cluster is invisible to the default (docker) provider and
    # the check wrongly returns false — causing a redundant re-create attempt.
    KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_RUNTIME:-docker}" \
        kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"
}

# ---------------------------------------------------------------------------
# _kind_registry_running  — returns 0 if the registry container is running
# ---------------------------------------------------------------------------
_kind_registry_running() {
    ${CONTAINER_RUNTIME:-docker} inspect --format='{{.State.Running}}' "${KIND_REGISTRY_NAME}" 2>/dev/null | grep -q "true"
}

# Returns 0 if the registry container exists (running or stopped)
_kind_registry_exists() {
    ${CONTAINER_RUNTIME:-docker} inspect "${KIND_REGISTRY_NAME}" &>/dev/null
}

# _start_local_registry — idempotent; removes a stopped container before starting fresh
_start_local_registry() {
    if _kind_registry_running; then
        write_to_log_file "INFO" "Local registry '${KIND_REGISTRY_NAME}' is already running"
        return 0
    fi

    if _kind_registry_exists; then
        write_to_log_file "INFO" "Removing stopped registry container '${KIND_REGISTRY_NAME}'..."
        ${CONTAINER_RUNTIME:-docker} rm -f "${KIND_REGISTRY_NAME}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    fi

    write_to_log_file "INFO" "Starting local registry (localhost:${KIND_REGISTRY_PORT})..."
    local runtime="${CONTAINER_RUNTIME:-docker}"
    local restart_flag="--restart=always"
    [[ "${runtime}" == "podman" ]] && restart_flag=""

    local network_flag="--network bridge"
    [[ "${runtime}" == "podman" ]] && network_flag=""

    ${runtime} run -d \
        ${restart_flag:+${restart_flag}} \
        --name "${KIND_REGISTRY_NAME}" \
        -p "127.0.0.1:${KIND_REGISTRY_PORT}:5000" \
        ${network_flag:+${network_flag}} \
        registry:2 >>"${LOG_FILE:-/dev/null}" 2>&1

    write_to_log_file "SUCCESS" "Local registry started at localhost:${KIND_REGISTRY_PORT}"
    return 0
}

# _check_ports_available — fails with a clear message if any required host port is in use.
# Only checks the two host-mapped Kind node ports (30000, 30004). Ports 30001 (Causa
# Backend), 30003 (Jafra MCP) and 30005 (Causa MCP) have no hostPort mapping and are not
# bound on the host — Causa Backend/MCP are reached via `kubectl port-forward`. Registry
# port is excluded because _start_local_registry runs first and manages it idempotently.
#
# gvproxy / rootlessport stale-lease exception (Linux rootless Podman only):
#   After all containers that owned a port mapping are removed, gvproxy keeps the
#   TCP listener alive as a stale lease for the remainder of the session.  When Kind
#   creates a new cluster it talks to the same gvproxy instance and reclaims those
#   leases successfully.  We suppress the hard-fail ONLY when the port is held by
#   gvproxy/rootlessport AND no running container is currently publishing that port —
#   confirming it is truly a stale lease rather than an active conflict.
_check_ports_available() {
    local ports=(30000 30004)
    local blocked=()
    local runtime="${CONTAINER_RUNTIME:-docker}"

    for port in "${ports[@]}"; do
        if lsof -iTCP:"${port}" -sTCP:LISTEN &>/dev/null 2>&1; then
            local owner
            owner=$(lsof -iTCP:"${port}" -sTCP:LISTEN -n -P 2>/dev/null \
                        | awk 'NR==2{print $1" (pid "$2")"}')
            # Stale gvproxy/rootlessport lease: the proxy holds the listener but
            # no running container is actively publishing this port — Kind will
            # successfully reclaim the lease.  Only suppress if confirmed stale.
            if echo "${owner}" | grep -qiE 'rootless|gvproxy'; then
                local active_container
                active_container=$(${runtime} ps --format '{{.Ports}}' 2>/dev/null \
                    | grep -c "0\.0\.0\.0:${port}->\|127\.0\.0\.1:${port}->" || true)
                if [[ "${active_container:-0}" -eq 0 ]]; then
                    write_to_log_file "INFO" "Port ${port} held by gvproxy/rootlessport (${owner}) with no active container — stale lease, Kind will reuse it"
                else
                    blocked+=("${port} — in use by active container via ${owner:-rootlessport}")
                    write_to_log_file "ERROR" "Port ${port} in use by a running container via ${owner:-unknown}"
                fi
            else
                blocked+=("${port} — in use by ${owner:-unknown process}")
                write_to_log_file "ERROR" "Port ${port} already in use: ${owner:-unknown}"
            fi
        fi
    done

    if [[ ${#blocked[@]} -gt 0 ]]; then
        log_error "Required ports are already in use:"
        for entry in "${blocked[@]}"; do
            log_error "  port ${entry}"
        done
        log_error "This usually means another application is occupying a required port."
        log_error "Free the ports above and re-run ./install.sh"
        return 1
    fi
    return 0
}

# _write_kind_config — writes cluster config YAML to a temp file and prints the path
_write_kind_config() {
    local config_file; config_file=$(mktemp /tmp/kind-config-XXXXXX.yaml)
    cat > "${config_file}" << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${KIND_CLUSTER_NAME}
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = false
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.test-handler.options]
      SystemdCgroup = false
kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    apiVersion: kubelet.config.k8s.io/v1beta1
    cgroupDriver: cgroupfs
nodes:
  - role: control-plane
    image: kindest/node:v1.31.14
    # causa-backend (8080) and causa-mcp (8081) are ClusterIP services reached
    # from the host via `kubectl port-forward` (see demo.sh), so they get no
    # host mapping here.  Only the k8s-mcp (30000) and quarkus-mcp (30004)
    # NodePorts are published to the host.
    extraPortMappings:
      - containerPort: 30000
        hostPort: 30000
        protocol: TCP
      - containerPort: 30004
        hostPort: 30004
        protocol: TCP
EOF
    echo "${config_file}"
}

# _connect_registry_to_kind_network — attaches the registry to the Kind network
_connect_registry_to_kind_network() {
    local runtime="${CONTAINER_RUNTIME:-docker}"
    if ${runtime} network inspect kind &>/dev/null; then
        if ${runtime} inspect "${KIND_REGISTRY_NAME}" \
            --format='{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' 2>/dev/null \
            | grep -q "$(${runtime} network inspect kind --format='{{.Id}}' 2>/dev/null)"; then
            write_to_log_file "INFO" "Registry already connected to 'kind' network"
        else
            ${runtime} network connect kind "${KIND_REGISTRY_NAME}" >>"${LOG_FILE}" 2>&1 || true
            write_to_log_file "SUCCESS" "Registry connected to 'kind' network"
        fi
    fi
}

# _write_registry_hosts_toml — writes the containerd v2 registry mirror config into each node
_write_registry_hosts_toml() {
    local runtime="${CONTAINER_RUNTIME:-docker}"
    local hosts_dir="/etc/containerd/certs.d/localhost:${KIND_REGISTRY_PORT}"
    local hosts_toml
    hosts_toml=$(printf '[host."http://%s:5000"]\n  capabilities = ["pull", "resolve"]\n' "${KIND_REGISTRY_NAME}")

    for node in $(KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_RUNTIME:-docker}" \
                    kind get nodes --name "${KIND_CLUSTER_NAME}" 2>/dev/null); do
        ${runtime} exec "${node}" mkdir -p "${hosts_dir}" >>"${LOG_FILE}" 2>&1
        ${runtime} exec "${node}" sh -c \
            "printf '%s\n' '${hosts_toml}' > ${hosts_dir}/hosts.toml" >>"${LOG_FILE}" 2>&1
        write_to_log_file "INFO" "Registry mirror hosts.toml written to node '${node}'"
    done
}

# _apply_registry_configmap — applies the standard local-registry-hosting ConfigMap
_apply_registry_configmap() {
    ${KUBE_CLI} apply -f - >>"${LOG_FILE}" 2>&1 << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${KIND_REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
    write_to_log_file "SUCCESS" "Local registry ConfigMap applied"
}

# _tune_kind_node_sysctls
#
# Kind nodes share the Linux kernel's sysctl namespace for inotify.
# inotify.max_user_instances defaults to 128 on most distros; repeated
# jafra-agent crash-loop restarts exhaust it, causing EMFILE (OS error 24,
# "Too many open files").
#
# On Linux the check reads /proc/sys directly.
# On macOS inotify lives inside the Docker/OrbStack/colima Linux VM, not on
# the macOS host, so the check is run via "docker exec" against the kind node.
# If the container runtime is unavailable the check is skipped with a warning.
#
# Compatible with bash 3.2+ (no associative arrays).
# Returns 1 with a clear remediation message if limits are too low.
_tune_kind_node_sysctls() {
    local _min_instances=512
    local _min_watches=1048576

    local _os
    _os=$(uname -s 2>/dev/null || echo "Linux")

    # ── Resolve how to read the sysctl values ─────────────────────────────────
    local _cur_instances _cur_watches
    local _remediation_header _remediation_cmds _remediation_persist

    if [[ "$_os" == "Darwin" ]]; then
        # macOS: inotify lives inside the kind node's Linux VM — exec into it.
        # Use the same runtime that was used to create the cluster so we exec
        # into the correct node container; do not probe for alternatives.
        local _runtime="${CONTAINER_RUNTIME:-docker}"

        if ! check_command_exists "$_runtime"; then
            log_warn "$_runtime not found on macOS — skipping inotify sysctl check."
            log_warn "If jafra-agent crashes with EMFILE, set inotify limits inside your Docker/OrbStack/colima VM."
            return 0
        fi

        # Verify the runtime daemon is actually responsive before exec'ing into a node.
        if ! "$_runtime" info &>/dev/null; then
            log_warn "$_runtime is installed but not running on macOS — skipping inotify sysctl check."
            log_warn "If jafra-agent crashes with EMFILE, start $_runtime and re-run, or set inotify limits inside the VM."
            return 0
        fi

        # Derive the kind node container name from KIND_CLUSTER_NAME (set by caller).
        local _node_container="${KIND_CLUSTER_NAME:-causa-rca}-control-plane"

        # Read each sysctl value separately so we can detect a missing/stopped
        # container rather than silently treating it as 0.
        _cur_instances=$("$_runtime" exec "$_node_container" \
            cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null)
        _cur_watches=$("$_runtime" exec "$_node_container" \
            cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null)

        if [[ -z "$_cur_instances" || -z "$_cur_watches" ]]; then
            log_warn "Could not read inotify sysctls from kind node '$_node_container' — skipping check."
            log_warn "The container may not be running. If jafra-agent crashes with EMFILE, set:"
            log_warn "  $_runtime exec --privileged $_node_container sysctl -w fs.inotify.max_user_instances=$_min_instances"
            log_warn "  $_runtime exec --privileged $_node_container sysctl -w fs.inotify.max_user_watches=$_min_watches"
            return 0
        fi

        _remediation_header="inotify limits inside the kind node VM are too low for the jafra-agent."
        _remediation_cmds=\
"  $_runtime exec --privileged $_node_container sysctl -w fs.inotify.max_user_instances=$_min_instances
  $_runtime exec --privileged $_node_container sysctl -w fs.inotify.max_user_watches=$_min_watches"
        _remediation_persist=\
"Or configure your VM runtime (Docker Desktop / OrbStack / colima) to set:
  fs.inotify.max_user_instances = $_min_instances
  fs.inotify.max_user_watches   = $_min_watches"
    else
        # Linux: read directly from /proc/sys on the host.
        _cur_instances=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
        _cur_watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)

        _remediation_header="Host inotify limits are too low for the jafra-agent."
        _remediation_cmds=\
"  sudo sysctl -w fs.inotify.max_user_instances=$_min_instances
  sudo sysctl -w fs.inotify.max_user_watches=$_min_watches"
        _remediation_persist=\
"To persist across reboots, add to /etc/sysctl.d/99-kind.conf:
  fs.inotify.max_user_instances = $_min_instances
  fs.inotify.max_user_watches   = $_min_watches"
    fi

    # ── Compare values against minimums (same logic for both OS paths) ────────
    local _needs_action=false

    if [[ "$_cur_instances" -lt "$_min_instances" ]]; then
        _needs_action=true
        log_file_only "sysctl fs.inotify.max_user_instances is $_cur_instances (minimum required: $_min_instances)"
    else
        log_file_only "sysctl fs.inotify.max_user_instances = $_cur_instances (ok)"
    fi

    if [[ "$_cur_watches" -lt "$_min_watches" ]]; then
        _needs_action=true
        log_file_only "sysctl fs.inotify.max_user_watches is $_cur_watches (minimum required: $_min_watches)"
    else
        log_file_only "sysctl fs.inotify.max_user_watches = $_cur_watches (ok)"
    fi

    if [[ "$_needs_action" == "true" ]]; then
        log_error "$_remediation_header"
        log_error "The agent will crash with EMFILE (error 24: Too many open files)."
        log_error "Run the following to fix:"
        log_error "$_remediation_cmds"
        log_error "$_remediation_persist"
        return 1
    fi

    write_to_log_file "SUCCESS" "inotify sysctls OK (max_user_instances and max_user_watches meet minimums)"
    return 0
}

# install_kind_cluster — start registry → create cluster → wire registry
install_kind_cluster() {
    log_section_silent "Provisioning Kind Cluster"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Kind cluster creation"
        return 0
    fi

    local runtime="${CONTAINER_RUNTIME:-docker}"
    if ! ${runtime} info &>/dev/null; then
        log_error "${runtime} is not running. Start it and retry."
        return 1
    fi

    if ! _start_local_registry; then
        return 1
    fi

    if _kind_cluster_exists; then
        write_to_log_file "INFO" "Kind cluster '${KIND_CLUSTER_NAME}' already exists — skipping creation"
    else
        if ! _check_ports_available; then
            return 1
        fi

        # Guard against orphaned node containers from a previous broken uninstall.
        # Kind checks container names before creating — if a container named
        # <cluster>-control-plane still exists (even in Exited state) because a
        # prior `kind delete cluster` removed the Kind record but left the container
        # behind, `kind create cluster` fails with "node(s) already exist".
        # Match only the exact Kind node suffixes to avoid touching unrelated
        # containers that happen to share the cluster-name prefix.
        local orphaned
        orphaned=$(${runtime} ps -a --format '{{.Names}}' 2>/dev/null \
            | grep -E "^${KIND_CLUSTER_NAME}-(control-plane|worker[0-9]*)$" || true)
        if [[ -n "${orphaned}" ]]; then
            write_to_log_file "WARN" "Orphaned Kind node container(s) found — removing before cluster creation..."
            echo "${orphaned}" | xargs ${runtime} rm -f >>"${LOG_FILE}" 2>&1 || true
            write_to_log_file "SUCCESS" "Orphaned containers removed"
        fi

        local kind_config
        kind_config=$(_write_kind_config)
        write_to_log_file "INFO" "Creating Kind cluster '${KIND_CLUSTER_NAME}'..."

        if ! KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_RUNTIME}" \
                kind create cluster --config "${kind_config}" >>"${LOG_FILE}" 2>&1; then
            log_error "Failed to create Kind cluster '${KIND_CLUSTER_NAME}'"
            rm -f "${kind_config}"
            return 1
        fi
        rm -f "${kind_config}"
        write_to_log_file "SUCCESS" "Kind cluster '${KIND_CLUSTER_NAME}' created"
    fi

    # Check inotify sysctls after the cluster node container is confirmed running —
    # both for newly created and pre-existing clusters.  On macOS the check
    # exec's into the kind node; on Linux it reads /proc/sys on the host.
    # Runs unconditionally so re-running the installer against an existing cluster
    # still catches host or VM limits that were lowered since the last install.
    if ! _tune_kind_node_sysctls; then
        log_error "inotify sysctl check failed — aborting Kind cluster setup"
        return 1
    fi

    ${KUBE_CLI} config use-context "kind-${KIND_CLUSTER_NAME}" >>"${LOG_FILE}" 2>&1 || true
    write_to_log_file "INFO" "kubectl context set to kind-${KIND_CLUSTER_NAME}"

    _connect_registry_to_kind_network
    _write_registry_hosts_toml
    _apply_registry_configmap

    write_to_log_file "SUCCESS" "Kind cluster '${KIND_CLUSTER_NAME}' is ready"
    write_to_log_file "INFO"    "Local registry: localhost:${KIND_REGISTRY_PORT}"
    write_to_log_file "INFO"    "Push images:    ${CONTAINER_RUNTIME:-docker} tag <img> localhost:${KIND_REGISTRY_PORT}/<name>:<tag> && ${CONTAINER_RUNTIME:-docker} push localhost:${KIND_REGISTRY_PORT}/<name>:<tag>"
    return 0
}

# uninstall_kind_cluster — deletes the cluster and removes the registry container
uninstall_kind_cluster() {
    log_section_silent "Removing Kind Cluster"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Kind cluster deletion"
        return 0
    fi

    local runtime="${CONTAINER_RUNTIME:-docker}"

    # ── Step 1: Capture cluster existence BEFORE removing containers ──────────
    # _kind_cluster_exists uses `kind get clusters` which discovers clusters from
    # their node containers.  We must check this BEFORE removing the containers,
    # otherwise the check always returns false and `kind delete cluster` is
    # skipped — leaving the kubeconfig context and Kind bookkeeping behind.
    local cluster_existed=false
    _kind_cluster_exists && cluster_existed=true

    # ── Step 2: Force-remove Kind node containers to release host ports ───────
    # Match only the exact Kind node suffixes (-control-plane, -worker, -worker2…)
    # to avoid accidentally removing unrelated containers that share the cluster
    # name prefix (e.g. causa-rca-helper when cluster is named causa-rca).
    #
    # Port-release behaviour differs by OS/runtime:
    #   macOS (Podman VM):  removing the container is sufficient for gvproxy to
    #     drop the port lease immediately.
    #   Linux rootless Podman: gvproxy keeps port leases alive for the session;
    #     _check_ports_available handles this by confirming no active container
    #     holds the port before treating it as a stale lease.
    local node_containers
    node_containers=$(${runtime} ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E "^${KIND_CLUSTER_NAME}-(control-plane|worker[0-9]*)$" || true)
    if [[ -n "${node_containers}" ]]; then
        write_to_log_file "INFO" "Force-removing Kind node containers to release host ports..."
        echo "${node_containers}" | xargs ${runtime} rm -f >>"${LOG_FILE}" 2>&1 || true
        write_to_log_file "SUCCESS" "Kind node containers removed (ports 30000/30004 freed)"
    fi

    # ── Step 3: Delete the cluster record from kind's bookkeeping ─────────────
    # Use the existence flag captured in Step 1 — not a fresh check — because
    # the node containers are already gone and kind get clusters would return
    # false even for a cluster that was genuinely present.
    if [[ "${cluster_existed}" == "true" ]]; then
        write_to_log_file "INFO" "Deleting Kind cluster '${KIND_CLUSTER_NAME}'..."
        if ! KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_RUNTIME:-docker}" \
                kind delete cluster --name "${KIND_CLUSTER_NAME}" >>"${LOG_FILE}" 2>&1; then
            # node containers are already removed above; kind delete may emit a
            # harmless "node not found" error — treat that as success, fail on
            # anything else.
            local delete_log
            delete_log=$(tail -5 "${LOG_FILE}" 2>/dev/null || true)
            if echo "${delete_log}" | grep -qiE 'not found|no nodes'; then
                write_to_log_file "INFO" "kind delete cluster: nodes already absent — kubeconfig cleanup completed"
            else
                log_error "kind delete cluster failed — kubeconfig context may be stale"
                log_error "Run manually: kind delete cluster --name ${KIND_CLUSTER_NAME}"
                return 1
            fi
        fi
        write_to_log_file "SUCCESS" "Kind cluster '${KIND_CLUSTER_NAME}' deleted"
    else
        write_to_log_file "INFO" "Kind cluster '${KIND_CLUSTER_NAME}' not found — nothing to delete"
    fi

    # ── Step 4: Remove the local registry ────────────────────────────────────
    if _kind_registry_exists; then
        write_to_log_file "INFO" "Stopping and removing local registry '${KIND_REGISTRY_NAME}'..."
        ${runtime} stop "${KIND_REGISTRY_NAME}" >>"${LOG_FILE}" 2>&1 || true
        ${runtime} rm -f "${KIND_REGISTRY_NAME}" >>"${LOG_FILE}" 2>&1 || true
        write_to_log_file "SUCCESS" "Local registry removed"
    fi

    return 0
}
export -f install_kind_cluster
export -f uninstall_kind_cluster
