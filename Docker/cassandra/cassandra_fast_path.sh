#!/bin/bash
set -e

CONTAINER_ID="${1:?Usage: $0 <container_id_or_name>}"
JMX_HOST="localhost:7199"
JMXTERM_JAR="/tmp/jmxterm-1.0.4-uber.jar"
JMXTERM_URL="https://github.com/jiaqi/jmxterm/releases/download/v1.0.4/jmxterm-1.0.4-uber.jar"

# Download jmxterm to the container if not already present
docker exec "$CONTAINER_ID" bash -c "test -f $JMXTERM_JAR || curl -sL -o $JMXTERM_JAR $JMXTERM_URL"

jmx_get() {
  local bean_name="$1"
  local attribute="$2"
  docker exec "$CONTAINER_ID" bash -c "
cat > /tmp/jmx_cmds.txt << INNER
domain org.apache.cassandra.metrics
bean $bean_name
get $attribute
INNER
java -jar $JMXTERM_JAR -l $JMX_HOST -i /tmp/jmx_cmds.txt -n
" 2>/dev/null | grep "^$attribute" | grep -oP '\d+'
}

for scope in rw ro; do
  FAST=$(jmx_get "org.apache.cassandra.metrics:name=FastPaths,scope=$scope,type=AccordCoordinator" Count)
  MEDIUM=$(jmx_get "org.apache.cassandra.metrics:name=MediumPaths,scope=$scope,type=AccordCoordinator" Count)
  SLOW=$(jmx_get "org.apache.cassandra.metrics:name=SlowPaths,scope=$scope,type=AccordCoordinator" Count)

  FAST=${FAST:-0}
  MEDIUM=${MEDIUM:-0}
  SLOW=${SLOW:-0}

  if [ "$scope" = "ro" ]; then
    EPHEMERAL=$(jmx_get "org.apache.cassandra.metrics:name=Ephemeral,scope=$scope,type=AccordCoordinator" Count)
    EPHEMERAL=${EPHEMERAL:-0}
    SCOPE_TOTAL=$((FAST + MEDIUM + SLOW + EPHEMERAL))
    if [ "$SCOPE_TOTAL" -gt 0 ]; then
	echo "Ephemeral ratio: $(awk "BEGIN {printf \"%.4f\", $EPHEMERAL/$SCOPE_TOTAL}")"
    fi
  else
    SCOPE_TOTAL=$((FAST + MEDIUM + SLOW))
    if [ "$SCOPE_TOTAL" -gt 0 ]; then
	echo "Fast ratio: $(awk "BEGIN {printf \"%.4f\", $FAST/$SCOPE_TOTAL}")"
	echo "Medium ratio: $(awk "BEGIN {printf \"%.4f\", $MEDIUM/$SCOPE_TOTAL}")"
	echo "Slow ratio: $(awk "BEGIN {printf \"%.4f\", $SLOW/$SCOPE_TOTAL}")"
    fi
  fi
done
