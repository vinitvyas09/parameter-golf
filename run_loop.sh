#!/usr/bin/env bash
set -uo pipefail

# Usage:
#   ./run_loop.sh [max_hours] [branch_tag]
#   ./run_loop.sh [max_hours] [branch_tag] --resume

MAX_HOURS="${1:-24}"
BRANCH_TAG="${2:-$(date +%b%d | tr '[:upper:]' '[:lower:]')}"
MODE="${3:-fresh}"

case "$MODE" in
  fresh|"")
    RESUME=0
    ;;
  --resume|resume)
    RESUME=1
    ;;
  *)
    echo "Usage: ./run_loop.sh [max_hours] [branch_tag] [--resume]"
    exit 1
    ;;
esac

START_TIME=$(date +%s)
ITERATION=0
LOG_FILE="orchestrator.log"

DATA_PATH="${DATA_PATH:-./data/datasets/fineweb10B_sp1024}"
TOKENIZER_PATH="${TOKENIZER_PATH:-./data/tokenizers/fineweb_1024_bpe.model}"

FRESH_STATE_FILES=(
  backward-looking.md
  forward-looking.md
  current_dev_task.md
  last_run_result.md
  run.log
  STOP
  results.tsv
)

RESUME_CLEANUP_FILES=(
  current_dev_task.md
  run.log
  STOP
)

RESEARCH_TIMEOUT=900
DEVELOPER_TIMEOUT=1800

# Replace `claude -p` below with your preferred non-interactive agent CLI
# if you are not using Claude Code.
RESEARCH_PROMPT="Read program.md and execute one Research Agent iteration."
DEVELOPER_PROMPT="Read developer_program.md and execute one Developer Agent iteration."

run_research_agent() {
  timeout "$RESEARCH_TIMEOUT" claude -p "$RESEARCH_PROMPT"
}

run_developer_agent() {
  timeout "$DEVELOPER_TIMEOUT" claude -p "$DEVELOPER_PROMPT"
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE"
}

verify_gpus() {
  if ! nvidia-smi -L >/dev/null 2>&1; then
    log "ERROR: nvidia-smi failed — no GPU found"
    exit 1
  fi
  local gpu_count
  gpu_count=$(nvidia-smi -L | wc -l | tr -d ' ')
  log "Verified $gpu_count GPU(s) available. Harness uses 1."
}

verify_data() {
  local train_count val_count
  train_count=$(compgen -G "$DATA_PATH/fineweb_train_*.bin" | wc -l | tr -d ' ')
  val_count=$(compgen -G "$DATA_PATH/fineweb_val_*.bin" | wc -l | tr -d ' ')
  if [ "$train_count" -eq 0 ]; then
    log "ERROR: no training shards found under $DATA_PATH"
    exit 1
  fi
  if [ "$val_count" -eq 0 ]; then
    log "ERR: no validation shards found under $DATA_PATH"
    exit 1
  fi
  if [ ! -f "$TOKENIZER_PATH" ]; then
    log "ERROR: tokenizer not found at $TOKENIZER_PATH"
    exit 1
  fi
  log "Verified data path $DATA_PATH ($train_count train shards, $val_count val shards)."
  log "Verified tokenizer path $TOKENIZER_PATH."
}

bootstrap() {
  local branch="pgolf/${BRANCH_TAG}"
  verify_gpus
  verify_data

  if [ "$RESUME" -eq 1 ]; then
    if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
      log "ERROR: branch $branch does not exist."
      exit 1
    fi
    git switch "$branch"
    # Ensure upstream tracking is set (may be missing if branch was created manually for seeding).
    git push -u origin "$branch" 2>/dev/null || true
    rm -f "${RESUME_CLEANUP_FILES[@]}"
    rm -f final_model.pt final_model*.ptz
  else
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
      log "ERROR: branch $branch already exists. Use --resume."
      exit 1
    fi
    git switch -c "$branch"
    # Set upstream tracking so `git push` works without arguments.
    # Non-fatal if no remote is configured (e.g., local-only dev).
    git push -u origin "$branch" 2>/dev/null || log "NOTE: initial push failed — will retry after first commit."
    rm -f "${FRESH_STATE_FILES[@]}"
    rm -f final_model.pt final_model*.ptz
    rm -rf logs/
    printf 'commit\tval_bpb\tmemory_gb\tstatus\tdescription\n' > results.tsv
  fi
}

bootstrap
log "Starting loop for up to ${MAX_HOURS}h"

while true; do
  elapsed=$(( $(date +%s) - START_TIME ))
  if [ "$elapsed" -ge $(( MAX_HOURS * 3600 )) ]; then
    log "Time budget exhausted after $ITERATION iterations."
    break
  fi

  ITERATION=$(( ITERATION + 1 ))
  elapsed_hours=$(awk "BEGIN { printf \"%.1f\", $elapsed / 3600 }")
  log "=== Iteration $ITERATION | Elapsed: ${elapsed_hours}h ==="

  # Clean only the stale task file. Do NOT delete last_run_result.md
  # yet; the Research Agent may need to consume it.
  rm -f current_dev_task.md

  RESULT_PRESENT=0
  if [ -f last_run_result.md ]; the    RESULT_PRESENT=1
  fi

  if run_research_agent; then
    log "Research Agent completed."
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then
      log "Research Agent timed out after ${RESEARCH_TIMEOUT}s. Retrying..."
    else
      log "Research Agent failed (exit $rc). Retrying..."
    fi
    sleep 10
    continue
  fi

  if [ -f STOP ]; then
    [ "$RESULT_PRESENT" -eq 1 ] && rm -f last_run_result.md
    log "STOP detected: $(cat STOP)"
    break
  fi

  if [ ! -f current_dev_task.md ]; then
    log "ERROR: Research Agent did not create current_dev_task.md. Preserving last_run_result.md for retry."
    sleep 5
    continue
  fi

  # Research Agent has consumed the previous result; safe to remove.
  [ "$RESULT_PRESENT" -eq 1 ] && rm -f last_run_result.md

  log "Spawning Developer Agent..."

  PRE_DEV_HEAD=$(git rev-parse HEAD)

  if run_developer_agent; then
    log "Developer Agent completed."
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then
      log "Developer Agent timed out after ${DEVELOPER_TIMEOUT}s."
    else
      log "Developer Agent failed (exit $rc)."
    fi
    log "Resetting train_gpt.py to last committed state."
    git restore --source=HEAD --worktree train_gpt.py || true
  fi

  # Push to remote if the Developer Agent committed a new experiment.
  # Non-fatal: if the push fails (no remote, auth issue, network blip),
  # log a warning and continue — the commit is still safe locally.
  POST_DEV_HEAD=$(git rev-parse HEAD)
  if [ "$PRE_DEV_HEAD" != "$POST_DEV_HEAD" ]; then
    if git push 2>/dev/null; then
      log "Pushed new commit $(git rev-parse --short HEAD) to remote."
    else
      log "WARNING: git push failed — commit is local only. Check remote/auth."
    fi
  fi

  rm -f final_model.pt final_model*.ptz

  if [ ! -f last_run_result.md ]; then
    log "WARNING: Developer Agent did not create last_run_result.md"
  fi

  sleep 5
done

total_elapsed=$(( $(date +%s) - START_TIME ))
total_hours=$(awk "BEGIN { printf \"%.1f\", $total_elapsed / 3600 }")
log "Loop complete. $ITERATION itions in ${total_hours}h."

