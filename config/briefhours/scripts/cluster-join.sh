#!/bin/bash
#
# BriefHours Cluster Join Script
# Runs on first boot to initialize or join the cluster
#

set -euo pipefail

# Load node configuration
source /etc/briefhours/node.conf

# Logging
LOG_FILE="/var/log/briefhours/cluster-join.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "=============================================="
echo "  BriefHours Cluster Join"
echo "=============================================="
echo "  Node Role:    ${NODE_ROLE}"
echo "  Node Number:  ${NODE_NUMBER}"
echo "  Node IP:      ${NODE_IP}"
echo "  Timestamp:    $(date -Iseconds)"
echo "=============================================="
echo ""

# Helper functions
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "FATAL: $*"; exit 1; }

# Wait for network connectivity
wait_for_network() {
    log "Waiting for network..."
    for i in {1..30}; do
        if ping -c 1 -W 2 10.0.0.1 &>/dev/null; then
            log "Network available"
            return 0
        fi
        sleep 2
    done
    die "Network timeout"
}

# Wait for Docker to be ready
wait_for_docker() {
    log "Waiting for Docker..."
    for i in {1..30}; do
        if docker info &>/dev/null; then
            log "Docker available"
            return 0
        fi
        sleep 2
    done
    die "Docker timeout"
}

# Wait for another node to be reachable
wait_for_node() {
    local node_ip="$1"
    local port="${2:-2379}"
    local timeout="${3:-60}"

    log "Waiting for node ${node_ip}:${port}..."
    for i in $(seq 1 $timeout); do
        if nc -z -w 2 "$node_ip" "$port" 2>/dev/null; then
            log "Node ${node_ip}:${port} reachable"
            return 0
        fi
        sleep 2
    done
    log "WARN: Node ${node_ip}:${port} not reachable after ${timeout}s"
    return 1
}

# Create docker-compose files
create_docker_compose() {
    log "Creating Docker Compose configuration..."

    mkdir -p /opt/briefhours

    # etcd compose file
    cat > /opt/briefhours/docker-compose.etcd.yml << 'COMPOSE_ETCD'
version: '3.8'

services:
  etcd:
    image: quay.io/coreos/etcd:v3.5.11
    container_name: briefhours-etcd
    restart: unless-stopped
    environment:
      - ETCD_NAME=${ETCD_NAME}
      - ETCD_DATA_DIR=/etcd-data
      - ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
      - ETCD_ADVERTISE_CLIENT_URLS=http://${NODE_IP}:2379
      - ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380
      - ETCD_INITIAL_ADVERTISE_PEER_URLS=http://${NODE_IP}:2380
      - ETCD_INITIAL_CLUSTER=${ETCD_INITIAL_CLUSTER}
      - ETCD_INITIAL_CLUSTER_STATE=${ETCD_INITIAL_CLUSTER_STATE}
      - ETCD_INITIAL_CLUSTER_TOKEN=briefhours-cluster
    volumes:
      - etcd-data:/etcd-data
    ports:
      - "2379:2379"
      - "2380:2380"
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  etcd-data:
COMPOSE_ETCD

    # Patroni compose file (for primary/replica only)
    if [ "$IS_WITNESS" != "true" ]; then
        cat > /opt/briefhours/docker-compose.patroni.yml << 'COMPOSE_PATRONI'
version: '3.8'

services:
  patroni:
    image: ghcr.io/zalando/patroni:v3.2.2
    container_name: briefhours-patroni
    restart: unless-stopped
    environment:
      - PATRONI_SCOPE=${PATRONI_SCOPE}
      - PATRONI_NAME=${PATRONI_NAME}
      - PATRONI_RESTAPI_LISTEN=0.0.0.0:8008
      - PATRONI_RESTAPI_CONNECT_ADDRESS=${NODE_IP}:8008
      - PATRONI_ETCD3_HOSTS=${PRIMARY_IP}:2379,${REPLICA_IP}:2379,${WITNESS_IP}:2379
      - PATRONI_POSTGRESQL_LISTEN=0.0.0.0:5432
      - PATRONI_POSTGRESQL_CONNECT_ADDRESS=${NODE_IP}:5432
      - PATRONI_POSTGRESQL_DATA_DIR=/var/lib/postgresql/data
      - PATRONI_REPLICATION_USERNAME=replicator
      - PATRONI_REPLICATION_PASSWORD=replicator_password
      - PATRONI_SUPERUSER_USERNAME=postgres
      - PATRONI_SUPERUSER_PASSWORD=postgres_password
      - PATRONI_POSTGRESQL_PGPASS=/tmp/pgpass
    volumes:
      - /var/lib/postgresql/data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
      - "8008:8008"
    depends_on:
      - etcd
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8008/health"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  default:
    external: true
    name: briefhours-network
COMPOSE_PATRONI
    fi
}

# Initialize primary node
join_as_primary() {
    log "=== Joining as PRIMARY node ==="

    cd /opt/briefhours

    # Create Docker network
    docker network create briefhours-network 2>/dev/null || true

    # Start etcd first (as leader)
    log "Starting etcd as initial leader..."
    docker compose -f docker-compose.etcd.yml up -d

    # Wait for etcd to be healthy
    log "Waiting for etcd to be healthy..."
    for i in {1..30}; do
        if docker exec briefhours-etcd etcdctl endpoint health &>/dev/null; then
            log "etcd is healthy"
            break
        fi
        sleep 2
    done

    # Start Patroni (PostgreSQL)
    log "Starting Patroni (PostgreSQL primary)..."
    docker compose -f docker-compose.patroni.yml up -d

    # Wait for Patroni/PostgreSQL to be ready
    log "Waiting for PostgreSQL to be ready..."
    for i in {1..60}; do
        if docker exec briefhours-patroni pg_isready -U postgres &>/dev/null; then
            log "PostgreSQL is ready"
            break
        fi
        sleep 3
    done

    log "Primary node initialization complete"
}

# Join as replica node
join_as_replica() {
    log "=== Joining as REPLICA node ==="

    cd /opt/briefhours

    # Wait for primary node's etcd
    wait_for_node "$PRIMARY_IP" 2379 120 || die "Primary node etcd not available"

    # Create Docker network
    docker network create briefhours-network 2>/dev/null || true

    # Start etcd (join existing cluster)
    log "Starting etcd (joining cluster)..."

    # Add self to etcd cluster first
    docker run --rm --network host quay.io/coreos/etcd:v3.5.11 \
        etcdctl --endpoints=http://${PRIMARY_IP}:2379 member add ${ETCD_NAME} \
        --peer-urls=http://${NODE_IP}:2380 2>/dev/null || log "WARN: etcd member add failed (may already exist)"

    docker compose -f docker-compose.etcd.yml up -d

    # Wait for etcd to join
    log "Waiting for etcd to join cluster..."
    for i in {1..30}; do
        if docker exec briefhours-etcd etcdctl endpoint health &>/dev/null; then
            log "etcd joined cluster"
            break
        fi
        sleep 2
    done

    # Wait for primary PostgreSQL
    wait_for_node "$PRIMARY_IP" 5432 60 || die "Primary PostgreSQL not available"

    # Start Patroni (will replicate from primary)
    log "Starting Patroni (PostgreSQL replica)..."
    docker compose -f docker-compose.patroni.yml up -d

    # Wait for replication to start
    log "Waiting for PostgreSQL replication to sync..."
    for i in {1..120}; do
        if docker exec briefhours-patroni patronictl list 2>/dev/null | grep -q "running"; then
            log "Patroni is running"
            break
        fi
        sleep 5
    done

    log "Replica node initialization complete"
}

# Join as witness node (etcd only)
join_as_witness() {
    log "=== Joining as WITNESS node ==="

    cd /opt/briefhours

    # Wait for primary node's etcd
    wait_for_node "$PRIMARY_IP" 2379 120 || die "Primary node etcd not available"

    # Add self to etcd cluster first
    log "Adding witness to etcd cluster..."
    docker run --rm --network host quay.io/coreos/etcd:v3.5.11 \
        etcdctl --endpoints=http://${PRIMARY_IP}:2379 member add ${ETCD_NAME} \
        --peer-urls=http://${NODE_IP}:2380 2>/dev/null || log "WARN: etcd member add failed (may already exist)"

    # Start etcd
    log "Starting etcd (witness mode)..."
    docker compose -f docker-compose.etcd.yml up -d

    # Wait for etcd to join
    log "Waiting for etcd to join cluster..."
    for i in {1..30}; do
        if docker exec briefhours-etcd etcdctl endpoint health &>/dev/null; then
            log "etcd joined cluster as witness"
            break
        fi
        sleep 2
    done

    log "Witness node initialization complete"
}

# Main
main() {
    wait_for_network
    wait_for_docker
    create_docker_compose

    case "${NODE_ROLE}" in
        primary)
            join_as_primary
            ;;
        replica)
            join_as_replica
            ;;
        witness)
            join_as_witness
            ;;
        *)
            die "Unknown role: ${NODE_ROLE}"
            ;;
    esac

    echo ""
    log "=============================================="
    log "  Cluster join complete!"
    log "=============================================="
    echo ""
}

main "$@"
