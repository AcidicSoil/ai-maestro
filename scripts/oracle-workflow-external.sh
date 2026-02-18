#!/usr/bin/env bash
#
# Run Oracle orchestrator against an external repository.
# Keeps orchestration assets in ai-maestro while executing context/metrics in target repo.
#
# Usage:
#   scripts/oracle-workflow-external.sh --repo /path/to/project --config scripts/oracle-orchestrator.config.json --mode daily
#   scripts/oracle-workflow-external.sh --repo /path/to/project --config scripts/oracle-orchestrator.config.json --mode threshold --job-id change-load-high
#
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_SCRIPT="$SELF_DIR/oracle-orchestrator.sh"

REPO=""
CONFIG=""
MODE="all"
JOB_ID=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Oracle Workflow External Runner

Required:
  --repo <path>           External project path to run workflow against
  --config <path>         Orchestrator config path

Optional:
  --mode <daily|threshold|all>   Job mode (default: all)
  --job-id <id>                  Run one job
  --dry-run                      Do not execute Oracle/relay
  -h, --help                     Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
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

if [[ -z "$REPO" || -z "$CONFIG" ]]; then
  echo "Error: --repo and --config are required" >&2
  usage
  exit 1
fi

if [[ ! -d "$REPO" ]]; then
  echo "Error: repo not found: $REPO" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: config not found: $CONFIG" >&2
  exit 1
fi

if [[ ! -x "$ORCH_SCRIPT" ]]; then
  echo "Error: orchestrator not executable: $ORCH_SCRIPT" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required" >&2
  exit 1
fi

REPO_ABS="$(realpath "$REPO")"
CONFIG_ABS="$(realpath "$CONFIG")"
AMP_SCRIPT_ABS="$SELF_DIR/../plugin/plugins/ai-maestro/scripts/amp-send.sh"

if [[ ! -x "$AMP_SCRIPT_ABS" ]]; then
  echo "Error: AMP script not executable: $AMP_SCRIPT_ABS" >&2
  exit 1
fi

TMP_CONFIG="$(mktemp)"
cleanup() {
  rm -f "$TMP_CONFIG"
}
trap cleanup EXIT

# Rewrite only path-sensitive values for external execution.
jq --arg amp "$AMP_SCRIPT_ABS" \
   --arg state "$REPO_ABS/.oracle-orchestrator-state.json" \
   '.relay.amp_script = $amp | .state_file = $state' \
   "$CONFIG_ABS" > "$TMP_CONFIG"

pushd "$REPO_ABS" >/dev/null

CMD=("$ORCH_SCRIPT" "--config" "$TMP_CONFIG" "--mode" "$MODE")
if [[ -n "$JOB_ID" ]]; then
  CMD+=("--job-id" "$JOB_ID")
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  CMD+=("--dry-run")
fi

echo "[oracle-workflow-external] repo=$REPO_ABS mode=$MODE job_id=${JOB_ID:-all}"
"${CMD[@]}"

popd >/dev/null
