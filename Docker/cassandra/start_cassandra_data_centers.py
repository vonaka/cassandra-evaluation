import docker, sys, time, math, re, csv, os
from datetime import datetime

def debug(msg):
    if config["debug"]:
        timestamp = datetime.now().strftime("%s:%f")
        print(f"[{timestamp}] \033[32m{msg}\033[0m")

def read_locations(file_path):
    """
    Read lat, lon, and loc from the CSV file.
    """
    locations = []
    with open(file_path, 'r') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            locations.append((float(row['lat']), float(row['lon']), row['loc']))
    return locations
        
def wait_for_log(container, log_pattern, timeout=300):
    log_stream = container.logs(stream=True)
    start_time = time.time()
    for log in log_stream:
        if re.search(log_pattern, log.decode('utf-8')):
            debug(f"Log pattern '{log_pattern}' found in container '{container.name}'.")
            return True
        if time.time() - start_time > timeout:
            print(f"Timeout ({timeout}s) waiting for '{log_pattern}' in container '{container.name}'. Last logs:")
            for line in container.logs().decode('utf-8', errors='replace').splitlines()[-30:]:
                print(f"  {line}")
            return False
    # Stream ended — container exited before the pattern appeared
    container.reload()
    print(f"Container '{container.name}' exited (status={container.status}) before '{log_pattern}' appeared. Last logs:")
    for line in container.logs().decode('utf-8', errors='replace').splitlines()[-30:]:
        print(f"  {line}")
    return False

def create_cassandra_cluster(num_nodes, cassandra_image):
    client = docker.from_env()
    network_name = config["network_name"]

    # Remove any leftover containers from a previous run
    for i in range(1, num_nodes+1):
        cname = f'{config["node_name"]}{i}'
        try:
            client.containers.get(cname).remove(force=True)
            debug(f"Removed existing container '{cname}'")
        except docker.errors.NotFound:
            pass

    # Determine resource limits from gcp.csv if machine type is specified
    nano_cpus = None
    mem_limit = None
    cassandra_xmx = None
    cassandra_xms = None
    active_processor_count = str(max(1, (os.cpu_count() or 1) // num_nodes))
    machine = config.get("machine", "")
    ephemeral_read_enabled = config.get("accord.ephemeral_read_enabled", "true")

    actual_mem_gb = 0
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    actual_mem_gb = int(line.split()[1]) / 1048576
                    break
    except Exception:
        pass

    if machine:
        try:
            with open(os.path.join(os.path.dirname(__file__), '..', 'gcp.csv'), 'r') as gcp_file:
                gcp_reader = csv.DictReader(gcp_file)
                for gcp_row in gcp_reader:
                    if gcp_row['name'] == machine:
                        memory_gb = float(gcp_row['memory'])
                        if actual_mem_gb == 0 or memory_gb <= actual_mem_gb:
                            nano_cpus = int(float(gcp_row['vcpus']) * 1e9)
                            mem_limit = int(memory_gb * 1024 * 1024 * 1024 * 4/5) # need some headroom
                            cassandra_xmx = f"{math.floor(memory_gb)}g"
                            cassandra_xms = "2g"
                            active_processor_count = gcp_row['vcpus']
                        break
        except FileNotFoundError:
            debug(f"gcp.csv not found, no resource limits applied for machine '{machine}'")

    if cassandra_xmx is None:
        cassandra_xmx = "4g"
        cassandra_xms = "2g"
    
    # Start the Cassandra nodes
    containers = []
    log_pattern = r"Startup complete"
    for i in range(1, num_nodes+1):
        container_name = f'{config["node_name"]}{i}'
        _, _, dc_name = locations[i-1]
        try:
            run_kwargs = dict(
                image=cassandra_image,
                name=container_name,
                network=network_name,
                security_opt=[
                "seccomp=unconfined",
                "apparmor=unconfined",
                "label=disable",
                ],
                log_config=docker.types.LogConfig(
                    type="json-file",
                    config={
                        "max-size": "10m",  # Max size per log file (e.g. 10MB)
                        "max-file": "3"     # Max number of rotated log files to keep
                    }),
                tmpfs={"/tmp/tmpfs": "rw,nosuid,nodev,mode=1777"},
                ulimits=[docker.types.Ulimit(name="memlock", soft=-1, hard=-1)],
                environment={
                    "JVM_OPTS" : " -Xms"+cassandra_xms+" -Xmx"+cassandra_xmx+" -XX:ActiveProcessorCount="+active_processor_count,
                    "CASSANDRA_ENDPOINT_SNITCH": "GossipingPropertyFileSnitch",
                    "CASSANDRA_SEEDS": f'{config["node_name"]}1' if i > 1 else "",
                    "CASSANDRA_CLUSTER_NAME": "TestCluster",
                    "CASSANDRA_DC": dc_name,
                    "CASSANDRA_RACK": "RAC1",
                    "CASSANDRA_EPHEMERAL_READ_ENABLED": ephemeral_read_enabled
                },
                cap_add=["NET_ADMIN"],  # Add NET_ADMIN capability,
                ports={ '9042/tcp': ('127.0.0.1', (3333+i)), '5005/tcp': ('127.0.0.1', (5005+i)) },
                detach=True
            )
            if nano_cpus is not None:
                run_kwargs['nano_cpus'] = nano_cpus
            if mem_limit is not None:
                run_kwargs['mem_limit'] = mem_limit
            container = client.containers.run(**run_kwargs)
            containers.append(container)            
            debug(f"Starting container '{container_name}' in data center '{dc_name}'.")
            if not wait_for_log(container, log_pattern):
                debug(f"Failed to start container '{container_name}' within the timeout period.")
                exit(-1)
        except docker.errors.APIError as e:
            debug(f"Error starting container '{container_name}': {e}")

    debug(f"Started {num_nodes} Cassandra nodes.")
    
if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 start_cassandra_data_centers.py <num_nodes> <cassandra_image>")
        sys.exit(1)

    try:        
        num_nodes = int(sys.argv[1])
        protocol = sys.argv[2]
        if protocol != "accord" and protocol != "paxos" and protocol != "quorum" and protocol != "one":
            raise ValueError("Protocol must be either 'accord', 'paxos', 'quorum', or 'one' ")
        if num_nodes < 1:
            raise ValueError("Number of nodes must be at least 1.")

        locations = read_locations('latencies.csv')
        
        config = {}
        with open('exp.config', 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue  # Skip empty lines and comments
                if '=' in line:
                    key, value = line.split('=', 1)
                    value = value.strip()
                    # Try to cast to int, then float, else keep as string
                    try:
                        value = int(value)
                    except ValueError:
                        try:
                            value = float(value)
                        except ValueError:
                            pass
                    config[key.strip()] = value
                    
        cassandra_image = config["accord_cassandra_image"] if protocol == "accord" else config["normal_cassandra_image"]
    except ValueError as e:
        print(f"Invalid parameters: {e}")
        sys.exit(1)

    create_cassandra_cluster(num_nodes, cassandra_image)
