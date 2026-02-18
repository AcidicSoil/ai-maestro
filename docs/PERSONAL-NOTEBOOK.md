# Personal Notebook: AI Maestro Workflow

Use this as a practical, low-friction playbook for running projects in AI Maestro.

## Simplest Repeatable Setup

1. Start AI Maestro:
```bash
yarn dev
```
2. Open `http://localhost:23000`
3. Create 2 agents for your project:
   - `project-feature-dev`
   - `project-feature-review`
4. Set each agent's working directory to the same repo path.
5. Use `dev` agent for implementation, `review` agent for validation and tests.

## 2-Agent Template (Default)

### Agent 1: `project-feature-dev`
- Purpose: implement code changes quickly.
- Typical tasks:
  - write feature code
  - run local checks while building
  - prepare commit-ready diffs

### Agent 2: `project-feature-review`
- Purpose: independent verification.
- Typical tasks:
  - run full tests/lint/build
  - review diffs for regressions
  - reproduce bugs and validate fixes

## New Project Bootstrap (Copy/Paste)

Run these in the `dev` agent terminal:

```bash
mkdir -p ~/projects
cd ~/projects
git clone <repo-url> <repo-name>
cd <repo-name>

# If needed by repo:
# cp .env.example .env.local

yarn install || npm install
yarn test || npm test
yarn build || npm run build
```

Then in AI Maestro:
1. Create `project-feature-dev` and `project-feature-review`
2. Point both to `~/projects/<repo-name>`
3. Keep implementation in `dev`; only verification in `review`

## Existing Project Bootstrap (Copy/Paste)

```bash
cd <existing-repo-path>
git status
yarn install || npm install
yarn test || npm test
```

Then create the same 2-agent pair and set working directory to this repo path.

## Daily Working Loop

1. `dev` agent:
   - pick one small task
   - implement
   - run targeted checks
2. `review` agent:
   - pull latest branch state
   - run broader checks (test/build/lint)
   - report risks and missing tests
3. Merge only after both pass.

## Project Naming Convention

Use names that auto-group well in sidebar hierarchy:

- `client-website-dev`
- `client-website-review`
- `internal-ai-maestro-dev`
- `internal-ai-maestro-review`

## Notes Template (Per Agent)

Copy this into the agent Notes area:

```md
## Goal
<single sentence>

## Current Task
<task id or short description>

## Commands Run
- <command>
- <command>

## Decisions
- <decision + reason>

## Next Step
<one concrete next action>
```

## Quick Troubleshooting

- App running check: `http://localhost:23000/api/sessions`
- No sessions visible: ensure `tmux` is installed and running sessions exist
- Build fails on first setup: run `yarn test` first, then `yarn build`
- Port conflict: set `PORT=23000` in `.env.local` (or change to a free port)

## Personal Session Log

Use this block at the end of each day:

```md
### YYYY-MM-DD
- Project:
- Branch:
- Completed:
- Blockers:
- First task for next session:
```

## Two-Machine Layout (Recommended Starter)

Use this when one machine starts feeling slow or you want continuous background execution.

### Host Roles

### Host A: `primary-laptop`
- Role: interactive coding and decision making.
- Run here:
  - `*-dev` agents
  - quick local checks
  - code edits and commits

### Host B: `worker-desktop` (MacBook/PC)
- Role: heavy and long-running tasks.
- Run here:
  - `*-review` agents
  - full test/lint/build loops
  - indexing and long jobs

## Agent Naming Pattern (Cross-Host)

Use consistent names so role is obvious:

- `project-api-dev` on `primary-laptop`
- `project-api-review` on `worker-desktop`
- `project-web-dev` on `primary-laptop`
- `project-web-review` on `worker-desktop`

## Daily Split Workflow

1. Start coding on `*-dev` (Host A).
2. When a change is ready, send validation to `*-review` (Host B).
3. `*-review` runs:
```bash
yarn test && yarn build
```
4. If green, merge or continue; if red, send failure details back to `*-dev`.

## Promotion Checklist (When to Add Host B)

Add a second machine when at least 2 are true:

- You wait on test/build more than 20-30% of your session.
- Your laptop fans/CPU are constantly saturated.
- You run tasks that take >10 minutes repeatedly.
- You need overnight/background jobs while laptop sleeps.
- You need another OS/toolchain (macOS vs Linux).

## Minimum Commands for Worker Host

Run once per project on Host B:

```bash
git clone <repo-url> <repo-name>
cd <repo-name>
yarn install || npm install
```

Daily update on Host B:

```bash
cd <repo-name>
git pull
yarn test
yarn build
```

## Host Onboarding Reference (Add New MacBook/PC)

Use this checklist whenever adding a new machine to your mesh.

### 1) Run on the New Machine

```bash
# Install + start AI Maestro service
curl -fsSL https://raw.githubusercontent.com/23blocks-OS/ai-maestro/main/scripts/remote-install.sh | sh -s -- -y --auto-start

# Confirm local service is up
curl -s http://localhost:23000/api/sessions
```

### 2) Recommended Network Setup (Tailscale)

```bash
tailscale up
tailscale ip -4
```

Use the returned Tailscale IP as your peer URL:
- `http://<tailscale-ip>:23000`

### 3) Capture Required Connection Info

Run this on the new machine:

```bash
curl -s http://localhost:23000/api/hosts/identity
```

Record:
- `host.id`
- `host.name`
- `host.url`
- `host.version`
- `host.tailscale`

### 4) Validate From Primary Machine

```bash
curl -s http://<new-machine-ip>:23000/api/sessions
curl -s http://<new-machine-ip>:23000/api/hosts/identity
```

If both return JSON, the machine is reachable and ready to add.

### 5) Add in Dashboard

1. Open AI Maestro on primary machine.
2. Go to `Settings` -> `Add Host`.
3. Enter `http://<new-machine-ip>:23000`.
4. Click `Discover Host`, then `Add Host`.

## One-Command Host Readiness Check

Run on any candidate machine before adding it:

```bash
bash -lc '
set -e
echo "== Hostname =="
hostname
echo
echo "== Node / tmux =="
node -v
tmux -V
echo
echo "== Local AI Maestro =="
curl -sS http://localhost:23000/api/sessions | head -c 300; echo
echo
echo "== Host Identity =="
curl -sS http://localhost:23000/api/hosts/identity
echo
echo
echo "== Tailscale (optional) =="
if command -v tailscale >/dev/null 2>&1; then
  tailscale ip -4 || true
else
  echo "tailscale not installed"
fi
'
```

## Future Workflow Test: Oracle Relay Agent

Goal: validate a specialized agent that only uses `oracle` for external Q&A, then relays results back to another agent.

### Proposed Agents

- `ops-oracle-relay`
  - Responsibility: receive query requests, call `oracle`, return structured response.
  - Constraint: no unrelated coding tasks.
- `project-dev`
  - Responsibility: send query requests and consume returned answers for implementation decisions.

### Target Flow

1. `project-dev` sends request message to `ops-oracle-relay`.
2. `ops-oracle-relay` runs `oracle` with strict output format.
3. `ops-oracle-relay` replies with:
   - direct answer
   - confidence/uncertainty
   - key assumptions
   - source references (when applicable)

### Request Message Template

```md
task_id: <id>
question: <exact question>
required_output_format: <json|markdown sections>
constraints:
- no speculation
- include dates if time-sensitive
- include citations/links if factual
priority: <low|normal|high>
```

### Response Template

```md
task_id: <id>
answer: <short answer>
details:
- <key point 1>
- <key point 2>
assumptions:
- <assumption>
confidence: <high|medium|low>
sources:
- <url 1>
- <url 2>
```

### Test Plan (Later)

1. Create both agents in AI Maestro.
2. Send 3 test queries from `project-dev` to `ops-oracle-relay`:
   - one factual
   - one ambiguous
   - one time-sensitive
3. Validate:
   - response format consistency
   - useful confidence flags
   - source quality
   - turnaround latency
4. Decide whether to promote as standard workflow.

## Phase 2 Blueprint: Automated Oracle Orchestrator

Goal: run automated Oracle tasks on thresholds and on daily schedule, route by task type to specific ChatGPT project instruction profiles, and relay results to downstream agents.

### Core Components

1. Trigger engine
- Time-based trigger (example: end-of-day at `18:00` local).
- Threshold-based trigger (example: test failures >= `N`, backlog size >= `N`, blocker age >= `N` hours).

2. Router policy
- Classify task into a route key (`architecture`, `review`, `release`, `risk`).
- Select matching ChatGPT project profile (instructions + output schema).
- Use fallback route when confidence is low.

3. Oracle runner
- Build prompt from template + context snapshot.
- Call `oracle` with selected profile/model.
- Enforce strict response format.

4. Relay + persistence
- Send structured response to target agent via AMP.
- Persist request/response metadata for auditing and replay.

## Suggested Config (Reference)

```yaml
automation:
  timezone: "America/Denver"
  daily_jobs:
    - id: "eod-review"
      cron: "0 18 * * *"
      route: "review"
      target_agent: "project-dev"
  threshold_jobs:
    - id: "high-failure-risk"
      condition: "failing_tests >= 5"
      route: "risk"
      target_agent: "project-review"
    - id: "stale-blockers"
      condition: "oldest_blocker_hours >= 24"
      route: "planning"
      target_agent: "project-dev"

routes:
  review:
    project_profile: "gpt-project-review"
    model: "gpt-5"
    output_schema: "oracle_review_v1"
  risk:
    project_profile: "gpt-project-risk"
    model: "gpt-5"
    output_schema: "oracle_risk_v1"
  planning:
    project_profile: "gpt-project-planning"
    model: "gpt-5"
    output_schema: "oracle_plan_v1"
  fallback:
    project_profile: "gpt-project-general"
    model: "gpt-5"
    output_schema: "oracle_general_v1"
```

## Prompt Contract (Keep Stable)

Always include:
- `task_id`
- `route`
- `objective`
- `context_snapshot`
- `constraints`
- required output schema name

## Output Contract (Example)

```json
{
  "task_id": "abc-123",
  "route": "review",
  "summary": "short answer",
  "findings": ["item1", "item2"],
  "assumptions": ["assumption1"],
  "confidence": "medium",
  "recommended_next_actions": ["action1"],
  "sources": ["https://..."]
}
```

## Safety Guardrails

- Idempotency key per run (`job_id + time_window`) to avoid duplicate sends.
- Retry policy with cap (`max_attempts: 2`).
- Cooldown window for threshold jobs (example: 60 minutes).
- Human approval gate for high-impact routes (`risk`, `release`).
- Redact secrets before Oracle prompt submission.

## Rollout Plan

1. Week 1: enable only one daily job (`daily-project-brief`), no threshold jobs.
2. Week 2: add one threshold job (`change-load-high`), monitor noise rate.
3. Week 3: add risk route with approval gate.
4. Keep weekly review of:
   - trigger quality
   - response quality
   - actionability
   - false positive rate

## Implementation Scaffold (Ready Now)

Created files:
- `scripts/oracle-orchestrator.sh`
- `scripts/oracle-orchestrator.config.example.json`

### First Run

```bash
cp scripts/oracle-orchestrator.config.example.json scripts/oracle-orchestrator.config.json

# Edit config: enable jobs, set target agents, set metric commands
$EDITOR scripts/oracle-orchestrator.config.json

# Dry run (no oracle call, no relay)
scripts/oracle-orchestrator.sh \
  --config scripts/oracle-orchestrator.config.json \
  --mode all \
  --dry-run
```

### Manual Execution

```bash
# Daily jobs only
scripts/oracle-orchestrator.sh \
  --config scripts/oracle-orchestrator.config.json \
  --mode daily

# Threshold jobs only
scripts/oracle-orchestrator.sh \
  --config scripts/oracle-orchestrator.config.json \
  --mode threshold

# Specific job
scripts/oracle-orchestrator.sh \
  --config scripts/oracle-orchestrator.config.json \
  --mode all \
  --job-id daily-project-brief
```

### Default "Project Ops" Workflow Profile (Configured)

Current live config includes these jobs:
- `daily-project-brief` (`daily`): sends an execution brief (priorities, risks, next actions) using route `review`
- `change-load-high` (`threshold`): triggers when `git status --porcelain` file count is `>= 25`
- `todo-density-high` (`threshold`): triggers when `TODO|FIXME|HACK` count is `>= 120`

Common runs:

```bash
# Run only the daily brief
scripts/oracle-orchestrator.sh \
  --config scripts/oracle-orchestrator.config.json \
  --mode daily \
  --job-id daily-project-brief \
  --force

# Check threshold jobs manually
scripts/oracle-orchestrator.sh \
  --config scripts/oracle-orchestrator.config.json \
  --mode threshold \
  --force
```

### Example Scheduler Setup (cron)

```cron
# End-of-day review at 18:00
0 18 * * * cd /path/to/ai-maestro && scripts/oracle-orchestrator.sh --config scripts/oracle-orchestrator.config.json --mode daily >> /tmp/oracle-orchestrator.log 2>&1

# Threshold checks every 30 minutes
*/30 * * * * cd /path/to/ai-maestro && scripts/oracle-orchestrator.sh --config scripts/oracle-orchestrator.config.json --mode threshold >> /tmp/oracle-orchestrator.log 2>&1
```

### Run Against Other Repositories (Outside `ai-maestro`)

Use the external wrapper:
- `scripts/oracle-workflow-external.sh`

It runs context/metrics inside another repo while still using `ai-maestro` Oracle + AMP tooling.

```bash
# Dry-run daily brief for another project
scripts/oracle-workflow-external.sh \
  --repo /path/to/other-project \
  --config scripts/oracle-orchestrator.config.json \
  --mode daily \
  --job-id daily-project-brief \
  --dry-run

# Live threshold checks for another project
scripts/oracle-workflow-external.sh \
  --repo /path/to/other-project \
  --config scripts/oracle-orchestrator.config.json \
  --mode threshold
```

Notes:
- The wrapper rewrites `relay.amp_script` to an absolute path.
- State file is stored per target repo as `.oracle-orchestrator-state.json`.
- Route file globs are evaluated inside the target repo.
