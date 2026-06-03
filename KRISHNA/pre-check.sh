#!/usr/bin/env bash
clear
echo ""
echo ""
echo "====================================================="
echo "Pre-Check: Verifying environment and dependencies..."
echo "====================================================="
echo ""
# Verify Java 25+ is installed (parse `java -version` and check major version >= 25).
precheck_java() {
    version_str=$(java -version 2>&1 | awk -F '"' '/version/ {print $2; exit}') || true
    if [ -z "${version_str:-}" ]; then
        echo "Unable to determine Java version"; exit 1
    else
        major=${version_str%%.*}
        if [ "$major" -gt 24 ]; then
            echo "✅ Java version: $version_str"; 
        else
            echo "❌ Java $major detected; Java 25 or newer is required"; exit 1
        fi
    fi
}
precheck_java

## VERIFY OLLAMA service port is running
precheck_ollama() {
    OLLAMA_PORT=11434
    OLLAMA_URL="http://localhost:$OLLAMA_PORT"
    # Prefer checking the Ollama process or listening socket without issuing an HTTP request
    # (issuing a request prompts the server's Gin logger to print access lines).
    if pgrep -f "ollama serve" >/dev/null 2>&1; then
        echo "✅ Ollama process is running (detected by pgrep)."
    fi

    # Check for a listening socket on the port using available tools (no HTTP request).
    if command -v lsof >/dev/null 2>&1; then
        if lsof -iTCP:$OLLAMA_PORT -sTCP:LISTEN -Pn >/dev/null 2>&1; then
            echo "    -  ✅ Ollama is listening on port $OLLAMA_PORT"
            if command -v ollama >/dev/null 2>&1; then
                # Run `ollama -v` safely — don't let its failure stop the script
                if ollama_ver=$(ollama -v 2>/dev/null); then
                    echo "    -  ✅ $ollama_ver detected."
                fi
                curl http://localhost:11434/api/version >/dev/null 2>&1 && echo "    -  ✅ Successfully connected to Ollama API endpoint." || echo "    - ❌ Warning: Unable to connect to Ollama API endpoint (curl failed)."
            fi
        else
            echo "❌ Ollama is NOT listening on port $OLLAMA_PORT"; exit 1
        fi
    fi
}
precheck_ollama

# Verify Docker is installed (looks for "Docker" in `docker --version`).
precheck_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo "✅ Docker exists: $(docker --version 2>/dev/null)"
    else
        echo "❌ Docker is not installed. Please install Docker."; exit 1
    fi
}
precheck_docker

# Verify PostgreSQL is reachable on port 5432 and validate JDBC connectivity.
recommend_postgres_compose() {
    echo "❌ PostgreSQL is not reachable on localhost:5432."
    echo "    - 📝 Recommendation: run 'docker start petclinic-postgresql' if the container already exists, otherwise run 'docker-compose -f ./BOOTCAMP/DAY-1/docker-compose-postgresql.yml up -d'"
}

fail_postgres_check() {
    recommend_postgres_compose
    exit 1
}

start_existing_postgres_container() {
    if command -v docker >/dev/null 2>&1 && docker inspect petclinic-postgresql >/dev/null 2>&1; then
        if docker inspect -f '{{.State.Status}}' petclinic-postgresql 2>/dev/null | grep -qv '^running$'; then
            echo "    - Starting existing Docker container petclinic-postgresql."
            if docker start petclinic-postgresql >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi

    return 1
}

check_postgres_jdbc() {
    local jdbc_url
    local jdbc_user
    local jdbc_pass
    local classpath_file
    local java_source_dir
    local java_source_file
    local java_classpath

    jdbc_url="${POSTGRES_URL:-jdbc:postgresql://127.0.0.1:5432/petclinic}"
    jdbc_user="${POSTGRES_USER:-petclinic}"
    jdbc_pass="${POSTGRES_PASS:-petclinic}"

    if ! command -v javac >/dev/null 2>&1; then
        echo "❌ javac is not available; cannot perform the JDBC connection check."
        exit 1
    fi

    if ! command -v java >/dev/null 2>&1; then
        echo "❌ java is not available; cannot perform the JDBC connection check."
        exit 1
    fi

    classpath_file=$(mktemp) || exit 1
    java_source_dir=$(mktemp -d) || exit 1
    java_source_file="$java_source_dir/PostgresJdbcCheck.java"

    if ! ./mvnw -q -DskipTests dependency:build-classpath -Dmdep.outputFile="$classpath_file" >/dev/null 2>&1; then
        rm -f "$classpath_file"
        rm -rf "$java_source_dir"
        echo "❌ Unable to resolve the PostgreSQL JDBC classpath."
        exit 1
    fi

    cat > "$java_source_file" <<'EOF'
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

public class PostgresJdbcCheck {
    public static void main(String[] args) throws Exception {
        String jdbcUrl = args[0];
        String jdbcUser = args[1];
        String jdbcPass = args[2];

        try (Connection connection = DriverManager.getConnection(jdbcUrl, jdbcUser, jdbcPass);
             Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery("SELECT 1 FROM (SELECT 1) AS dual")) {
            if (!resultSet.next() || resultSet.getInt(1) != 1) {
                throw new IllegalStateException("Unexpected JDBC validation result");
            }
        }
    }
}
EOF

    java_classpath=$(cat "$classpath_file")

    if ! javac -cp "$java_classpath" "$java_source_file" >/dev/null 2>&1; then
        rm -f "$classpath_file"
        rm -rf "$java_source_dir"
        echo "    - ❌ Failed to compile the JDBC validation check."
        exit 1
    fi

    if java -cp "$java_source_dir:$java_classpath" PostgresJdbcCheck "$jdbc_url" "$jdbc_user" "$jdbc_pass" >/dev/null 2>&1; then
        echo "    - ✅ JDBC connection validated with SELECT 1 FROM dual-style query."
    else
        rm -f "$classpath_file"
        rm -rf "$java_source_dir"
        echo "    - ❌ JDBC connection failed for $jdbc_url using user '$jdbc_user'."
        exit 1
    fi

    rm -f "$classpath_file"
    rm -rf "$java_source_dir"
}

precheck_postgresql() {
    local postgres_port=5432
    local port_in_use=false

    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$postgres_port" >/dev/null 2>&1; then
        port_in_use=true
        echo "✅ PostgreSQL is listening on port $postgres_port"
    elif command -v lsof >/dev/null 2>&1 && lsof -iTCP:$postgres_port -sTCP:LISTEN -Pn >/dev/null 2>&1; then
        port_in_use=true
        echo "✅ A service is listening on port $postgres_port"
    fi

    if [ "$port_in_use" = true ]; then
        check_postgres_jdbc
        return 0
    fi

    if start_existing_postgres_container; then
        if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$postgres_port" >/dev/null 2>&1; then
            echo "✅ PostgreSQL is listening on port $postgres_port"
            check_postgres_jdbc
            return 0
        fi

        if command -v lsof >/dev/null 2>&1 && lsof -iTCP:$postgres_port -sTCP:LISTEN -Pn >/dev/null 2>&1; then
            echo "✅ A service is listening on port $postgres_port"
            check_postgres_jdbc
            return 0
        fi
    fi

    if command -v docker >/dev/null 2>&1; then
        if docker ps --filter "publish=$postgres_port" --format '{{.Names}}' | grep -q .; then
            echo "    - ✅ Docker is running a container that publishes port $postgres_port."
            check_postgres_jdbc
            return 0
        fi
    fi

    fail_postgres_check
}
precheck_postgresql


echo ""
echo "====================================================="
echo ""