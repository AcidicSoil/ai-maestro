#!/usr/bin/env bash
#
# Oracle Orchestrator (scaffold)
#
# Runs route-based Oracle queries and relays results via AMP.
# Supports:
# - Daily jobs (manual trigger for now)
# - Threshold jobs (metric command + operator + cooldown)
#
# Usage:
#   scripts/oracle-orchestrator.sh --config scripts/oracle-orchestrator.config.example.json --mode daily
#   scripts/oracle-orchestrator.sh --config scripts/oracle-orchestrator.config.example.json --mode threshold
#   scripts/oracle-orchestrator.sh --config scripts/oracle-orchestrator.config.example.json --mode all
#   scripts/oracle-orchestrator.sh --config ... --mode daily --job-id eod-review
#   scripts/oracle-orchestrator.sh --config ... --mode threshold --dry-run

set -euo pipefail

CONFIG=""
MODE="all"
JOB_ID=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Oracle Orchestrator

Required:
  --config <path>         Path to orchestrator config JSON

Optional:
  --mode <daily|threshold|all>   Job mode (default: all)
  --job-id <id>                  Run only one job by id
  --dry-run                      Print commands, do not execute oracle/relay
  -h, --help                     Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG="${2:-}"
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --job-id)
      JOB_ID="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$CONFIG" ]]; then
  echo "Error: --config is required" >&2
  usage
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: config not found: $CONFIG" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required" >&2
  exit 1
fi

ORACLE_BIN="$(jq -r '.oracle.binary // "oracle"' "$CONFIG")"
ORACLE_ENGINE="$(jq -r '.oracle.engine // "browser"' "$CONFIG")"
ORACLE_MODEL="$(jq -r '.oracle.model // "gpt-5.2-pro"' "$CONFIG")"
mapfile -t ORACLE_EXTRA_ARGS < <(jq -r '.oracle.extra_args[]? // empty' "$CONFIG")
ORACLE_PREFLIGHT_ENABLED="$(jq -r '.oracle.preflight.enabled // false' "$CONFIG")"
ORACLE_PREFLIGHT_REMOTE_HOST="$(jq -r '.oracle.preflight.remote_host // empty' "$CONFIG")"
ORACLE_PREFLIGHT_START_COMMAND="$(jq -r '.oracle.preflight.start_command // empty' "$CONFIG")"
ORACLE_PREFLIGHT_WAIT_SECONDS="$(jq -r '.oracle.preflight.wait_seconds // 30' "$CONFIG")"
ORACLE_PREFLIGHT_CHECK_INTERVAL_SECONDS="$(jq -r '.oracle.preflight.check_interval_seconds // 2' "$CONFIG")"
RELAY_METHOD="$(jq -r '.relay.method // "amp"' "$CONFIG")"
AMP_SCRIPT="$(jq -r '.relay.amp_script // "scripts/amp-send.sh"' "$CONFIG")"
FROM_AGENT="$(jq -r '.relay.from_agent // ""' "$CONFIG")"
TZ_NAME="$(jq -r '.timezone // "UTC"' "$CONFIG")"
STATE_FILE="$(jq -r '.state_file // ".oracle-orchestrator-state.json"' "$CONFIG")"

if [[ "$ORACLE_BIN" != "oracle" ]] && [[ "$ORACLE_BIN" != /* ]]; then
  ORACLE_BIN="$(realpath -m "$ORACLE_BIN")"
fi

extract_remote_host_from_args() {
  local i
  for (( i=0; i<${#ORACLE_EXTRA_ARGS[@]}; i++ )); do
    if [[ "${ORACLE_EXTRA_ARGS[$i]}" == "--remote-host" ]]; then
      if (( i + 1 < ${#ORACLE_EXTRA_ARGS[@]} )); then
        echo "${ORACLE_EXTRA_ARGS[$((i+1))]}"
        return 0
      fi
    fi
  done
  echo ""
}

hostport_reachable() {
  local hostport="$1"
  local host="${hostport%:*}"
  local port="${hostport##*:}"
  if [[ -z "$host" || -z "$port" || "$host" == "$port" ]]; then
    return 1
  fi
  timeout 2 bash -lc "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
}

wait_for_hostport() {
  local hostport="$1"
  local wait_seconds="$2"
  local interval="$3"
  local start now elapsed
  start="$(now_epoch)"
  while true; do
    if hostport_reachable "$hostport"; then
      return 0
    fi
    now="$(now_epoch)"
    elapsed=$(( now - start ))
    if (( elapsed >= wait_seconds )); then
      return 1
    fi
    sleep "$interval"
  done
}

preflight_oracle_remote() {
  if [[ "$ORACLE_ENGINE" != "browser" ]]; then
    return 0
  fi
  if [[ "$ORACLE_PREFLIGHT_ENABLED" != "true" ]]; then
    return 0
  fi

  local remote_host
  remote_host="$ORACLE_PREFLIGHT_REMOTE_HOST"
  if [[ -z "$remote_host" ]]; then
    remote_host="$(extract_remote_host_from_args)"
  fi
  if [[ -z "$remote_host" ]]; then
    echo "[oracle-orchestrator] preflight enabled but no remote host configured; skipping"
    return 0
  fi

  if hostport_reachable "$remote_host"; then
    echo "[oracle-orchestrator] preflight ok: remote host reachable ($remote_host)"
    return 0
  fi

  echo "[oracle-orchestrator] preflight: remote host not reachable ($remote_host)"
  if [[ -n "$ORACLE_PREFLIGHT_START_COMMAND" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[oracle-orchestrator] dry-run start command: $ORACLE_PREFLIGHT_START_COMMAND"
    else
      echo "[oracle-orchestrator] starting remote oracle service..."
      bash -lc "$ORACLE_PREFLIGHT_START_COMMAND" || true
    fi
  fi

  if wait_for_hostport "$remote_host" "$ORACLE_PREFLIGHT_WAIT_SECONDS" "$ORACLE_PREFLIGHT_CHECK_INTERVAL_SECONDS"; then
    echo "[oracle-orchestrator] preflight recovered: remote host reachable ($remote_host)"
    return 0
  fi

  echo "[oracle-orchestrator] preflight failed: remote host still unreachable ($remote_host)"
  echo "[oracle-orchestrator] hint: start oracle serve on remote machine and verify token/port"
  return 1
}

ensure_state_file() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"jobs":{}}' > "$STATE_FILE"
  fi
}

get_state_ts() {
  local key="$1"
  jq -r --arg k "$key" '.jobs[$k].last_sent_at // empty' "$STATE_FILE"
}

set_state_ts() {
  local key="$1"
  local ts="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --arg t "$ts" '.jobs[$k].last_sent_at = $t' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

now_epoch() {
  date +%s
}

iso_now() {
  TZ="$TZ_NAME" date -Iseconds
}

seconds_since() {
  local iso="$1"
  if [[ -z "$iso" ]]; then
    echo 999999999
    return
  fi
  local past now
  past="$(date -d "$iso" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$iso" +%s 2>/dev/null || echo 0)"
  now="$(now_epoch)"
  echo $(( now - past ))
}

eval_compare() {
  local metric="$1"
  local op="$2"
  local threshold="$3"
  case "$op" in
    ">")  awk "BEGIN {exit !($metric > $threshold)}" ;;
    ">=") awk "BEGIN {exit !($metric >= $threshold)}" ;;
    "<")  awk "BEGIN {exit !($metric < $threshold)}" ;;
    "<=") awk "BEGIN {exit !($metric <= $threshold)}" ;;
    "=="|"=") awk "BEGIN {exit !($metric == $threshold)}" ;;
    "!=") awk "BEGIN {exit !($metric != $threshold)}" ;;
    *)
      echo "Unknown operator: $op" >&2
      return 1
      ;;
  esac
}

build_prompt() {
  local job_json="$1"
  local route_json="$2"
  local context="$3"
  local route job_id objective schema profile instruction
  route="$(echo "$job_json" | jq -r '.route')"
  job_id="$(echo "$job_json" | jq -r '.id')"
  objective="$(echo "$job_json" | jq -r '.objective')"
  schema="$(echo "$route_json" | jq -r '.output_schema // "oracle_general_v1"')"
  profile="$(echo "$route_json" | jq -r '.profile_name // "gpt-project-general"')"
  instruction="$(echo "$route_json" | jq -r '.instruction // "Answer directly."')"

  cat <<EOF
task_id: $job_id
route: $route
profile_name: $profile
required_output_schema: $schema

objective:
$objective

custom_instructions:
$instruction

constraints:
- avoid speculation
- explicitly list assumptions
- include confidence (high|medium|low)
- keep response concise and actionable

context_snapshot:
$context

Return format:
1) summary
2) findings
3) assumptions
4) confidence
5) next_actions
6) sources (if used)
EOF
}

run_oracle() {
  local job_json="$1"
  local route_json="$2"
  local context="$3"
  local job_id route prompt output_file
  job_id="$(echo "$job_json" | jq -r '.id')"
  route="$(echo "$job_json" | jq -r '.route')"
  prompt="$(build_prompt "$job_json" "$route_json" "$context")"
  output_file="$(mktemp)"

  local -a cmd
  cmd=("$ORACLE_BIN" "--engine" "$ORACLE_ENGINE" "--model" "$ORACLE_MODEL")
  if [[ "${#ORACLE_EXTRA_ARGS[@]}" -gt 0 ]]; then
    cmd+=("${ORACLE_EXTRA_ARGS[@]}")
  fi
  cmd+=("-p" "$prompt")

  while IFS= read -r file_glob; do
    [[ -z "$file_glob" ]] && continue
    # Oracle CLI in this environment treats leading "!" patterns as literal paths.
    # Skip exclude globs to avoid ENOENT failures.
    if [[ "$file_glob" == "!"* ]]; then
      echo "[oracle-orchestrator] skip exclude pattern for oracle: $file_glob" >&2
      continue
    fi
    cmd+=("--file" "$file_glob")
  done < <(echo "$route_json" | jq -r '.files[]?')

  echo "[oracle-orchestrator] Running job=$job_id route=$route engine=$ORACLE_ENGINE model=$ORACLE_MODEL"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[oracle-orchestrator] dry-run oracle command:"
    printf '  %q' "${cmd[@]}"
    echo
    printf "[DRY-RUN] %s\n" "$prompt" > "$output_file"
  else
    "${cmd[@]}" > "$output_file"
  fi

  cat "$output_file"
  rm -f "$output_file"
}

relay_result() {
  local job_json="$1"
  local result="$2"
  local target subject
  target="$(echo "$job_json" | jq -r '.target_agent')"
  subject="$(echo "$job_json" | jq -r '.subject // "Oracle result"')"

  if [[ "$RELAY_METHOD" != "amp" ]]; then
    echo "[oracle-orchestrator] relay.method=$RELAY_METHOD not implemented; skipping relay"
    return 0
  fi

  if [[ ! -x "$AMP_SCRIPT" ]]; then
    echo "[oracle-orchestrator] AMP script not executable: $AMP_SCRIPT"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[oracle-orchestrator] dry-run relay to $target subject=$subject"
    return 0
  fi

  local -a relay_cmd
  relay_cmd=("$AMP_SCRIPT" "$target" "$subject" "$result")

  # New AMP scripts resolve agent identity from CLAUDE_AGENT_NAME/ID or tmux session.
  # Set CLAUDE_AGENT_NAME when provided so relay can run from non-tmux automation contexts.
  if [[ -n "$FROM_AGENT" ]]; then
    CLAUDE_AGENT_NAME="$FROM_AGENT" "${relay_cmd[@]}"
  else
    "${relay_cmd[@]}"
  fi
}

job_enabled() {
  local job_json="$1"
  [[ "$(echo "$job_json" | jq -r '.enabled // false')" == "true" ]]
}

job_matches_filter() {
  local job_json="$1"
  local id
  id="$(echo "$job_json" | jq -r '.id')"
  if [[ -z "$JOB_ID" ]]; then
    return 0
  fi
  [[ "$JOB_ID" == "$id" ]]
}

run_daily_jobs() {
  local count i job_json route route_json context result
  count="$(jq '.jobs.daily | length' "$CONFIG")"
  for (( i=0; i<count; i++ )); do
    job_json="$(jq -c ".jobs.daily[$i]" "$CONFIG")"
    if ! job_enabled "$job_json"; then
      continue
    fi
    if ! job_matches_filter "$job_json"; then
      continue
    fi

    route="$(echo "$job_json" | jq -r '.route')"
    route_json="$(jq -c --arg r "$route" '.routes[$r] // .routes.fallback' "$CONFIG")"
    context="$(bash -lc "$(echo "$job_json" | jq -r '.context_command // "echo no context command configured"')" 2>&1 | head -n 120)"
    result="$(run_oracle "$job_json" "$route_json" "$context")"
    relay_result "$job_json" "$result"
    set_state_ts "$(echo "$job_json" | jq -r '.id')" "$(iso_now)"
  done
}

run_threshold_jobs() {
  local count i job_json route route_json id metric_cmd metric op threshold cooldown_min elapsed context result
  count="$(jq '.jobs.threshold | length' "$CONFIG")"
  for (( i=0; i<count; i++ )); do
    job_json="$(jq -c ".jobs.threshold[$i]" "$CONFIG")"
    if ! job_enabled "$job_json"; then
      continue
    fi
    if ! job_matches_filter "$job_json"; then
      continue
    fi

    id="$(echo "$job_json" | jq -r '.id')"
    metric_cmd="$(echo "$job_json" | jq -r '.metric_command')"
    op="$(echo "$job_json" | jq -r '.operator')"
    threshold="$(echo "$job_json" | jq -r '.threshold')"
    cooldown_min="$(echo "$job_json" | jq -r '.cooldown_minutes // 60')"

    metric="$(bash -lc "$metric_cmd" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [[ -z "$metric" ]] || ! [[ "$metric" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
      echo "[oracle-orchestrator] skip id=$id invalid metric output: '$metric'"
      continue
    fi

    if ! eval_compare "$metric" "$op" "$threshold"; then
      echo "[oracle-orchestrator] skip id=$id condition false: $metric $op $threshold"
      continue
    fi

    elapsed="$(seconds_since "$(get_state_ts "$id")")"
    if (( elapsed < cooldown_min * 60 )); then
      echo "[oracle-orchestrator] skip id=$id cooldown active (${elapsed}s < $((cooldown_min*60))s)"
      continue
    fi

    route="$(echo "$job_json" | jq -r '.route')"
    route_json="$(jq -c --arg r "$route" '.routes[$r] // .routes.fallback' "$CONFIG")"
    context="metric_value=$metric
metric_condition=$metric $op $threshold
job_id=$id
timestamp=$(iso_now)"
    result="$(run_oracle "$job_json" "$route_json" "$context")"
    relay_result "$job_json" "$result"
    set_state_ts "$id" "$(iso_now)"
  done
}

ensure_state_file
preflight_oracle_remote

if [[ "$MODE" == "daily" || "$MODE" == "all" ]]; then
  run_daily_jobs
fi

if [[ "$MODE" == "threshold" || "$MODE" == "all" ]]; then
  run_threshold_jobs
fi

echo "[oracle-orchestrator] done"
