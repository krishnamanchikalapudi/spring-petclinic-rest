#!/bin/bash
arg="${1:-RESTART}"
ACTION=$(printf '%s' "$arg" | tr '[:lower:]' '[:upper:]' | xargs)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
else
    COMPOSE_CMD=(docker-compose)
fi

start() {
    echo "Starting Docker container..."
    kill_ports

    echo "✅ Docker compose started. Waiting for services to be healthy..."
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d --wait
    # wait_for_postgresql || echo "❌ Warning: PostgreSQL did not become ready in time."

    sleep 10
    info
    tail_logs
}
stop() {
    echo " Stopping Containers: services and cleaning up resources..."
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true

    docker rm -f $(docker ps -a -q --filter "name=petclinic" --filter "name=postgres" --filter "name=open-webui") >/dev/null 2>&1 || true

    kill_ports

    echo "✅ Containers stopped and cleaned up."
    info
}
container_using_port() {
    local port="$1"

    docker ps --format '{{.Names}}\t{{.Ports}}' | awk -F'\t' -v p=":${port}->" '$2 ~ p {print $1; exit}'
}
kill_ports() {
    local ports=(5432 3000 9966)
    local container
    for port in "${ports[@]}"; do
        container="$(container_using_port "${port}" || true)"
        if [[ -n "${container}" ]]; then
            echo "⚠️ Stopping container ${container} that is using port ${port}..."
            docker stop "${container}" >/dev/null 2>&1 || true
        fi
        if lsof -iTCP:"${port}" -sTCP:LISTEN -Pn >/dev/null 2>&1; then
            echo "⚠️ Killing process using port ${port}..."
            # kill -9 $(lsof -t -i:5432) >/dev/null 2>&1 || true
            kill -9 $(lsof -t -iTCP:"${port}" -sTCP:LISTEN -Pn) >/dev/null 2>&1 || true
            echo "✅ Port ${port} is now free."
        fi
    done
}
info(){
    echo "🧐 Current Docker containers are running:"
    docker container ls --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}" -a
}
validate_petclinic() {
    printf "\n *** GET: OWNERS \n"
    curl -X 'GET' 'http://localhost:9966/petclinic/api/owners' -H 'accept: application/json' > /dev/null 2>&1 || { echo "❌ Failed to connect to PetClinic API. Please check if the application is running."; }
    printf "\n *** GET: PetTypes \n"
    curl -X 'GET' 'http://localhost:9966/petclinic/api/pettypes' -H 'accept: application/json' > /dev/null 2>&1 || { echo "❌ Failed to connect to PetClinic API. Please check if the application is running.";  }
    printf "\n *** GET: VET \n"
    curl -X 'GET' 'http://localhost:9966/petclinic/api/vets' -H 'accept: application/json' > /dev/null 2>&1 || { echo "❌ Failed to connect to PetClinic API. Please check if the application is running.";  }
}
tail_logs() {
    echo "Tailing logs for all session 1 containers. Press Ctrl+C to stop."
    docker logs --follow --tail=100 -t petclinic &
}


echo "User Action: ${ACTION}"

case $ACTION in
    START)
        start
        ;;
    STOP)
        stop
        ;;
    RESTART)
        stop
        sleep 5
        start
        sleep 1
        echo "✅ Spring Boot application should be running on http://localhost:9966"
        open http://localhost:9966/petclinic/swagger-ui.html
        ;;
    VALIDATE|VAL)
        validate_petclinic
        ;;
    INFO)
        info
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|validate|info}"
        exit 1
        ;;
esac