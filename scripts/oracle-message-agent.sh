#!/usr/bin/env bash
#
# Oracle Message Agent
#
# Listens for unread AMP messages and executes Oracle requests based on subject:
#   Subject: oracle:<route>
#   Body: request/objective
#
# Example:
#   CLAUDE_AGENT_NAME=ops-oracle-relay scripts/oracle-message-agent.sh \
#     --config scripts/oracle-orchestrator.config.json --once
#
# Loop mode:
#   CLAUDE_AGENT_NAME=ops-oracle-relay scripts/oracle-message-agent.sh \
#     --config scripts/oracle-orchestrator.config.json --loop --interval 20
#
set -euo pipefail

CONFIG=""
RUN_ONCE=0
RUN_LOOP=0
INTERVAL=20
LIMIT=20
DRY_RUN=0

usage() {
  cat <<'EOF'
Oracle Message Agent

Required:
  --config <path>          Orchestrator config JSON (routes + oracle settings)

Modes:
  --once                   Process current unread messages and exit
  --loop                   Poll continuously

Optional:
  --interval <seconds>     Poll interval for --loop (default: 20)
  --limit <n>              Max unread messages per poll (default: 20)
  --dry-run                Do not run oracle/send reply
  -h, --help               Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG="${2:-}"
      shift 2
      ;;
    --once)
      RUN_ONCE=1
      shift
      ;;
    --loop)
      RUN_LOOP=1
      shift
      ;;
    --interval)
      INTERVAL="${2:-20}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:-20}"
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
  exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "Error: config not found: $CONFIG" >&2
  exit 1
fi
if [[ "$RUN_ONCE" -eq 0 && "$RUN_LOOP" -eq 0 ]]; then
  echo "Error: choose --once or --loop" >&2
  exit 1
fi
if [[ -z "${CLAUDE_AGENT_NAME:-}" ]]; then
  echo "Error: CLAUDE_AGENT_NAME must be set (listener agent identity)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMP_DIR="$SCRIPT_DIR/../plugin/plugins/ai-maestro/scripts"
AMP_INBOX="$AMP_DIR/amp-inbox.sh"
AMP_READ="$AMP_DIR/amp-read.sh"
AMP_SEND="$AMP_DIR/amp-send.sh"

for bin in "$AMP_INBOX" "$AMP_READ" "$AMP_SEND"; do
  if [[ ! -x "$bin" ]]; then
    echo "Error: required AMP script not executable: $bin" >&2
    exit 1
  fi
done

ORACLE_BIN="$(jq -r '.oracle.binary // "oracle"' "$CONFIG")"
ORACLE_ENGINE="$(jq -r '.oracle.engine // "browser"' "$CONFIG")"
ORACLE_MODEL="$(jq -r '.oracle.model // "gpt-5.2-pro"' "$CONFIG")"
mapfile -t ORACLE_EXTRA_ARGS < <(jq -r '.oracle.extra_args[]? // empty' "$CONFIG")

if [[ "$ORACLE_BIN" != "oracle" ]] && [[ "$ORACLE_BIN" != /* ]]; then
  ORACLE_BIN="$(realpath -m "$ORACLE_BIN")"
fi

build_prompt() {
  local msg_id="$1"
  local from="$2"
  local route="$3"
  local subject="$4"
  local body="$5"
  local instruction="$6"
  local profile="$7"
  local schema="$8"

  cat <<EOF
task_id: inbox-$msg_id
route: $route
profile_name: $profile
required_output_schema: $schema

objective:
Respond to this agent request with actionable output.

custom_instructions:
$instruction

request_context:
- sender: $from
- subject: $subject
- message_id: $msg_id

request_body:
$body

constraints:
- if unclear, state what is missing
- list assumptions explicitly
- include confidence (high|medium|low)

Return format:
1) summary
2) findings
3) assumptions
4) confidence
5) next_actions
EOF
}

run_oracle_for_message() {
  local msg_id="$1"
  local from="$2"
  local subject="$3"
  local body="$4"
  local route="$5"

  local route_json instruction profile schema prompt
  route_json="$(jq -c --arg r "$route" '.routes[$r] // .routes.fallback' "$CONFIG")"
  instruction="$(echo "$route_json" | jq -r '.instruction // "Answer directly."')"
  profile="$(echo "$route_json" | jq -r '.profile_name // "gpt-project-general"')"
  schema="$(echo "$route_json" | jq -r '.output_schema // "oracle_general_v1"')"
  prompt="$(build_prompt "$msg_id" "$from" "$route" "$subject" "$body" "$instruction" "$profile" "$schema")"

  local -a cmd
  cmd=("$ORACLE_BIN" "--engine" "$ORACLE_ENGINE" "--model" "$ORACLE_MODEL")
  if [[ "${#ORACLE_EXTRA_ARGS[@]}" -gt 0 ]]; then
    cmd+=("${ORACLE_EXTRA_ARGS[@]}")
  fi
  cmd+=("-p" "$prompt")

  while IFS= read -r file_glob; do
    [[ -z "$file_glob" ]] && continue
    if [[ "$file_glob" == "!"* ]]; then
      continue
    fi
    cmd+=("--file" "$file_glob")
  done < <(echo "$route_json" | jq -r '.files[]?')

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] route=$route"
    printf '  %q' "${cmd[@]}"
    echo
    return 0
  fi

  "${cmd[@]}"
}

send_help_reply() {
  local to="$1"
  local msg_id="$2"
  local subject="$3"
  local body
  body="Unsupported subject format: '$subject'

Use:
- oracle:review
- oracle:risk
- oracle:planning

Body should contain your request.
Ref message: $msg_id"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] help reply to $to"
    return 0
  fi
  CLAUDE_AGENT_NAME="$CLAUDE_AGENT_NAME" "$AMP_SEND" "$to" "oracle-help: $msg_id" "$body" >/dev/null
}

process_once() {
  local unread_json count i msg_id raw_json from subject body route result reply_subject
  unread_json="$(CLAUDE_AGENT_NAME="$CLAUDE_AGENT_NAME" "$AMP_INBOX" --unread --json --limit "$LIMIT")"
  count="$(echo "$unread_json" | jq 'length')"
  if [[ "$count" -eq 0 ]]; then
    echo "[oracle-message-agent] no unread messages"
    return 0
  fi

  for (( i=0; i<count; i++ )); do
    msg_id="$(echo "$unread_json" | jq -r ".[$i].envelope.id")"
    raw_json="$(CLAUDE_AGENT_NAME="$CLAUDE_AGENT_NAME" "$AMP_READ" "$msg_id" --json)"
    from="$(echo "$raw_json" | jq -r '.envelope.from')"
    subject="$(echo "$raw_json" | jq -r '.envelope.subject')"
    body="$(echo "$raw_json" | jq -r '.payload.message // ""')"

    if [[ "$subject" =~ ^[Oo][Rr][Aa][Cc][Ll][Ee]:([a-zA-Z0-9_-]+)$ ]]; then
      route="${BASH_REMATCH[1]}"
    else
      send_help_reply "$from" "$msg_id" "$subject"
      continue
    fi

    echo "[oracle-message-agent] processing id=$msg_id from=$from route=$route"
    if ! result="$(run_oracle_for_message "$msg_id" "$from" "$subject" "$body" "$route" 2>&1)"; then
      result="Oracle execution failed for message $msg_id (route=$route).

$result"
    fi

    reply_subject="oracle-result:$route:$msg_id"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] would reply to $from subject=$reply_subject"
      continue
    fi
    CLAUDE_AGENT_NAME="$CLAUDE_AGENT_NAME" "$AMP_SEND" "$from" "$reply_subject" "$result" >/dev/null
    echo "[oracle-message-agent] replied to $from for id=$msg_id"
  done
}

if [[ "$RUN_ONCE" -eq 1 ]]; then
  process_once
  exit 0
fi

echo "[oracle-message-agent] loop mode started (interval=${INTERVAL}s agent=${CLAUDE_AGENT_NAME})"
while true; do
  process_once || true
  sleep "$INTERVAL"
done

