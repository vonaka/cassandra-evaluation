#!/usr/bin/env bash

DIR=$(dirname "${BASH_SOURCE[0]}")
LOGDIR="${DIR}/logs"
RESULTSDIR="${DIR}/results/"
CONFIG_FILE="${DIR}/exp.config"

config() {
    if [ $# -ne 1 ]; then
        echo "usage: config key"
        exit -1
    fi
    local key=$1
    cat ${CONFIG_FILE} | grep -E "^${key}=" | cut -d= -f2
}

debug() {
    if [[ DEBUG -eq 1 ]]
    then
	local message="$@"
	echo -e >&1 "["$(date +%s:%N)"] \033[32m${message}\033[0m"
    fi
}

log() {
    local message="$@"
    echo -e >&1 "["$(date +%s:%N)"] \033[33m${message}\033[0m"
}

error() {
    local message="$@"
    echo -e >&2 "["$(date +%s:%N)"] \033[31m${message}\033[0m"
}

init_logdir() {
    mkdir -p ${LOGDIR};
}

clean_logdir() {
    rm -f ${LOGDIR}/*    
}

DEBUG=$(config debug)

start_container() {
    if [ $# -lt 4 ]; then
        error "usage: start_container <image> <name> <message> <logfile> [docker args...] [-- container_cmd...]"
        return 2
    fi

    local image="$1"
    local cname="$2"
    local wait_msg="$3"
    local log_file="$4"
    shift 4
    
    # Split arguments on "--" separator
    # Everything before "--" is docker_args, everything after is container_cmd
    local docker_args=()
    local container_cmd=()
    local found_separator=0
    
    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then
            found_separator=1
            shift
        elif [ $found_separator -eq 0 ]; then
            docker_args+=("$1")
            shift
        else
            container_cmd+=("$1")
            shift
        fi
    done
    
    log "Starting container from image '${image}' as '${cname}' using ${log_file} to log and args '${docker_args[*]}'"
    if [ ${#container_cmd[@]} -gt 0 ]; then
        log "Container command: ${container_cmd[*]}"
    fi
    
    local cid
    echo "docker run ${docker_args[@]} --name $cname $image ${container_cmd[@]}"
    cid=$(docker run ${docker_args[@]} --log-opt max-size=10m  --log-opt max-file=3 --name $cname $image ${container_cmd[@]} 2>&1) || {
         error "docker run failed: ${cid}"
         return 3
    }
    log "Started container '${cname}' (id: ${cid})"

    docker logs -f $cname > ${log_file} 2>&1 &

    local start_time
    start_time=$(date +%s)
    local timeout
    timeout=${START_CONTAINER_TIMEOUT:-90}   # seconds, override by exporting START_CONTAINER_TIMEOUT

    while true; do
        # Check for the readiness message in logs
        if docker logs "$cname" 2>&1 | grep -F -- "$wait_msg" >/dev/null; then
            log "Container '${cname}' is ready (found: '${wait_msg}')"
            return 0
        fi

        # Check whether container is still running
        local running
        running=$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null) || {
            error "Failed to inspect container '${cname}'"
            return 4
        }
        if [ "$running" != "true" ]; then
            local exit_code
            exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$cname" 2>/dev/null || echo "unknown")
            error "Container '${cname}' exited with code ${exit_code} before readiness message appeared. Logs:"
            docker logs "$cname" 2>&1 | sed 's/^/  /'
            return 5
        fi

        # Timeout check
        if (( $(date +%s) - start_time >= timeout )); then
            error "Timeout (${timeout}s) waiting for '${wait_msg}' in container '${cname}' logs. Logs:"
            docker logs "$cname" 2>&1 | sed 's/^/  /'
            return 6
        fi

        sleep 0.5
    done
}

wait_container() {
    if [ $# -lt 1 ]; then
        error "usage: wait_container <name>"
        return 2
    fi

    local cname="$1"

    # Wait until container is no longer running (or inspect disappears)
    log "Waiting container '${cname}' to terminate"
    while true; do
        running=$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null) || {
            # Inspect failing -> container removed or no longer present; treat as stopped
            log "Container '${cname}' no longer present; considered stopped"
            return 0
        }

        if [ "$running" != "true" ]; then
            log "Container '${cname}' stopped"
            return 0
        fi

        sleep 0.5
    done    
}

fetch_logs_container() {
    if [ $# -lt 1 ]; then
        error "usage: fetch_logs_container <name> [timeout_seconds]"
        return 2
    fi

    local cname="$1"
    
    docker logs "$cname" 2>&1 | sed 's/^/  /'    
}

stop_container() {
    if [ $# -lt 1 ]; then
        error "usage: stop_container <name> [timeout_seconds]"
        return 2
    fi

    local cname="$1"
    local timeout="${2:-${STOP_CONTAINER_TIMEOUT:-30}}"  # seconds, can be overridden by arg or STOP_CONTAINER_TIMEOUT env

    log "Stopping container '${cname}' (timeout: ${timeout}s)"

    # Check container existence / get running state
    local running
    running=$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null) || {
        error "Container '${cname}' does not exist or cannot be inspected"
        return 3
    }

    if [ "$running" != "true" ]; then
        log "Container '${cname}' is already stopped"
        return 0
    fi

    if ! docker stop "$cname" >/dev/null 2>&1; then
        error "docker stop failed for container '${cname}'"
        return 4
    fi

    local start_time
    start_time=$(date +%s)

    # Wait until container is no longer running (or inspect disappears)
    while true; do
        running=$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null) || {
            # Inspect failing -> container removed or no longer present; treat as stopped
            log "Container '${cname}' no longer present; considered stopped"
            return 0
        }
        if [ "$running" != "true" ]; then
            log "Container '${cname}' stopped"
            return 0
        fi

        if (( $(date +%s) - start_time >= timeout )); then
            error "Timeout (${timeout}s) waiting for container '${cname}' to stop"
            return 5
        fi

        sleep 0.5
    done
}

# Function to get the IP address of a container
get_container_ip() {
    container_name=$1
    ip_address=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name" 2>/dev/null)
    echo "$ip_address"
}

# Function to stop a container after a delay
stop_container_after_delay() {
    container_name=$1
    delay=$2
    (
        sleep "$delay"
        docker stop "$container_name"
        log "Stopped container '$container_name' after $delay seconds."
    ) &
}

get_resource_limits() {
    local machine
    machine=$(config machine)

    if [ -z "$machine" ]; then
        echo ""
        return 0
    fi

    local gcp_csv="${DIR}/gcp.csv"
    if [ ! -f "$gcp_csv" ]; then
        error "gcp.csv not found: ${gcp_csv}"
        echo ""
        return 1
    fi

    local row
    row=$(awk -F',' -v name="$machine" 'NR>1 && $1==name {print $0; exit}' "$gcp_csv")
    if [ -z "$row" ]; then
        error "Machine type '${machine}' not found in gcp.csv"
        echo ""
        return 1
    fi

    local vcpus memory_gb memory_mb
    vcpus=$(echo "$row" | cut -d',' -f2)
    memory_gb=$(echo "$row" | cut -d',' -f3)
    memory_mb=$(awk "BEGIN { printf \"%d\", ${memory_gb} * 1024 }")

    echo "--cpus ${vcpus} --memory ${memory_mb}m"
}

compute_test_machine() {
    local node_count=$1
    if [ -z "$node_count" ] || ! [[ "$node_count" =~ ^[0-9]+$ ]] || [ "$node_count" -le 0 ]; then
        error "compute_test_machine: node_count must be a positive integer"
        return 1
    fi

    # Get actual machine CPUs
    local actual_cpus
    actual_cpus=$(nproc)

    # Get actual machine memory in GB (1 GB = 1048576 kB)
    local actual_mem_kb
    actual_mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    local actual_mem_gb
    actual_mem_gb=$(awk "BEGIN { printf \"%.6f\", ${actual_mem_kb} / 1048576 }")

    local gcp_csv="${DIR}/gcp.csv"
    if [ ! -f "$gcp_csv" ]; then
        error "gcp.csv not found: ${gcp_csv}"
        return 1
    fi

    # Find the best spec s where actual_mem_gb <= s.g * node_count
    # gcp.csv columns: $1=name, $2=vcpus, $3=memory(GB)
    local machine
    machine=$(awk -F',' -v c="$actual_cpus" -v g="$actual_mem_gb" -v k="$node_count" '
        NR>1 && ($3+0)*k <= g+0 {
            if (best == "" || $2+0 >= best_c+0) {
                best = $1
                best_c = $2
                best_g = $3
            }
        }
        END { print best }
    ' "$gcp_csv")

    if [ -z "$machine" ]; then
        log "No suitable machine spec found for ${actual_cpus} CPUs and ${actual_mem_gb}GB memory with ${node_count} nodes; running without resource limits"
        sed -i "s/^machine=.*/machine=/" "${CONFIG_FILE}"
        return 0
    fi

    log "Test mode: machine spec '${machine}' for ${actual_cpus} CPUs, ${actual_mem_gb}GB memory, ${node_count} nodes"
    sed -i "s/^machine=.*/machine=${machine}/" "${CONFIG_FILE}"
    return 0
}

pull_images() {
    log "Pulling all Docker images from ${CONFIG_FILE}..."
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        [[ "$key" =~ _image$ ]] || continue
        value=$(echo "$value" | xargs)
        if docker image inspect "${value}" >/dev/null 2>&1; then
            log "Image '${value}' already present locally, skipping pull."
            continue
        fi
        log "Pulling image: ${value}"
        docker pull "${value}"
        if [ $? -ne 0 ]; then
            log "ERROR: Failed to pull image '${value}'. Aborting."
            exit 1
        fi
    done < "${CONFIG_FILE}"
    log "All Docker images pulled successfully."
}

get_location() {
  local k="$1"
  local file="${2:-latencies.csv}"

  # Validate arguments
  if [ -z "$k" ]; then
    echo "Usage: get_location <k> [file]" >&2
    return 2
  fi
  if ! [[ "$k" =~ ^[0-9]+$ ]] || [ "$k" -le 0 ]; then
    echo "Error: k must be a positive integer" >&2
    return 2
  fi
  if [ ! -r "$file" ]; then
    echo "Error: file '$file' not found or not readable" >&2
    return 3
  fi

  # Compute the target file line number (header is line 1)
  local target_line=$((k + 1))

  # Extract the 3rd CSV field from the target line.
  # NOTE: some awk implementations (e.g., busybox awk) do not accept "--" as an option terminator.
  # Do NOT pass "--" to awk; pass the filename as the last argument instead.
  local loc
  loc=$(awk -F',' -v n="$target_line" 'NR==n{
      field=$3
      gsub(/\r/,"",field)               # drop CR if file has CRLF
      sub(/^[ \t]+/,"",field)           # trim leading space
      sub(/[ \t]+$/,"",field)           # trim trailing space
      print field
    }' "$file") || { echo "Error: failed to read '$file' with awk" >&2; return 3; }

  if [ -z "$loc" ]; then
    echo "Error: no such data line (k=$k) in '$file'" >&2
    return 4
  fi

  # Strip surrounding double quotes if present
  loc="${loc%\"}"
  loc="${loc#\"}"

  # Extract leading alphabetic sequence for the location
  if [[ "$loc" =~ ^([A-Za-z]+) ]]; then
    printf '%s\n' "$(printf '%s' "${BASH_REMATCH[1]}")"
    return 0
  fi

  echo "Error: location value does not contain alphabetic name: '$loc'" >&2
  return 5
}
