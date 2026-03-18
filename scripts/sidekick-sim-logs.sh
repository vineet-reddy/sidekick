#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
RUNTIME_DIR="$REPO_ROOT/.sidekick-runtime"
META_FILE="$RUNTIME_DIR/sim-log-stream.env"
LATEST_LINK="$RUNTIME_DIR/latest-simulator.log"
DAEMON_SCRIPT="$SCRIPT_DIR/sidekick_sim_log_daemon.py"
INSTALL_DIR="$HOME/Library/Application Support/SidekickDevTools"
INSTALLED_DAEMON="$INSTALL_DIR/sidekick_sim_log_daemon.py"
LOG_DIR="$HOME/Library/Logs/Sidekick"
DEFAULT_PROCESS_NAME="${SIDEKICK_SIM_LOG_PROCESS:-Sidekick}"
if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/python3" ]]; then
  PYTHON_BIN="/Applications/Xcode.app/Contents/Developer/usr/bin/python3"
else
  PYTHON_BIN="$(command -v python3)"
fi
LAUNCH_AGENT_LABEL="com.vineet.sidekick.sim-log-capture"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"

mkdir -p "$RUNTIME_DIR"
mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"

usage() {
  cat <<'EOF'
Usage:
  scripts/sidekick-sim-logs.sh start [--process <name>] [--force]
  scripts/sidekick-sim-logs.sh stop
  scripts/sidekick-sim-logs.sh status
  scripts/sidekick-sim-logs.sh path
  scripts/sidekick-sim-logs.sh tail [--lines <n>] [--follow]
  scripts/sidekick-sim-logs.sh stream [--process <name>]

Behavior:
  start   Installs or refreshes a LaunchAgent that persists Sidekick simulator logs.
  stop    Stops the LaunchAgent-backed capture.
  status  Prints whether the capture agent is running and the current log path.
  path    Prints the latest persisted log file path.
  tail    Prints the latest persisted log file, optionally following it.
  stream  Streams live Sidekick unified logs in the foreground for this shell.

Environment:
  SIDEKICK_SIM_LOG_PROCESS   Override the default process filter (default: Sidekick)
EOF
}

read_meta_value() {
  local key="$1"
  if [[ -f "$META_FILE" ]]; then
    awk -F= -v wanted="$key" '$1 == wanted { sub($1 FS, ""); print; exit }' "$META_FILE"
  fi
}

write_meta() {
  local process_name="$1"
  local log_path="$2"
  local started_at="$3"

  cat >"$META_FILE" <<EOF
PROCESS_NAME=$process_name
LOG_PATH=$log_path
STARTED_AT=$started_at
LAUNCH_AGENT_LABEL=$LAUNCH_AGENT_LABEL
LAUNCH_AGENT_PLIST=$LAUNCH_AGENT_PLIST
EOF
}

agent_print() {
  launchctl print "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
}

running_pid() {
  local pid
  pid=$(agent_print | awk -F'= ' '/pid = / { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }')
  if [[ -n "$pid" && "$pid" != "0" ]]; then
    echo "$pid"
    return 0
  fi
  return 1
}

bootout_agent() {
  launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || \
    launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1 || true
}

write_plist() {
  local process_name="$1"
  local log_path="$2"
  local daemon_out="$LOG_DIR/sidekick-sim-log-capture.stdout.log"
  local daemon_err="$LOG_DIR/sidekick-sim-log-capture.stderr.log"

  cat >"$LAUNCH_AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCH_AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON_BIN</string>
    <string>-S</string>
    <string>$INSTALLED_DAEMON</string>
    <string>--process</string>
    <string>$process_name</string>
    <string>--log-path</string>
    <string>$log_path</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PYTHONNOUSERSITE</key>
    <string>1</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$daemon_out</string>
  <key>StandardErrorPath</key>
  <string>$daemon_err</string>
</dict>
</plist>
EOF
}

start_capture() {
  local process_name="$DEFAULT_PROCESS_NAME"
  local force="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --process)
        process_name="${2:-}"
        shift 2
        ;;
      --force)
        force="1"
        shift
        ;;
      *)
        echo "Unknown start option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if running_pid >/dev/null && [[ "$force" != "1" ]]; then
    echo "Simulator log capture is already running (pid $(running_pid))." >&2
    exit 1
  fi

  local started_at log_path archive_path
  started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  log_path="$LOG_DIR/sidekick-simulator-current.log"
  if [[ -f "$log_path" && -s "$log_path" ]]; then
    archive_path="$LOG_DIR/sidekick-simulator-$(date +"%Y%m%d-%H%M%S").log"
    mv "$log_path" "$archive_path"
  fi
  : >"$log_path"
  : >"$LOG_DIR/sidekick-sim-log-capture.stdout.log"
  : >"$LOG_DIR/sidekick-sim-log-capture.stderr.log"
  cp "$DAEMON_SCRIPT" "$INSTALLED_DAEMON"
  chmod +x "$INSTALLED_DAEMON"
  ln -sf "$log_path" "$LATEST_LINK"

  write_plist "$process_name" "$log_path"
  bootout_agent
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"
  sleep 1

  write_meta "$process_name" "$log_path" "$started_at"

  echo "Started simulator log capture."
  if running_pid >/dev/null; then
    echo "pid=$(running_pid)"
  fi
  echo "process_name=$process_name"
  echo "log_path=$log_path"
  echo "launch_agent=$LAUNCH_AGENT_LABEL"
}

stop_capture() {
  local pid=""
  if running_pid >/dev/null; then
    pid=$(running_pid)
  fi
  bootout_agent
  if [[ -n "$pid" ]]; then
    echo "Stopped simulator log capture (pid $pid)."
  else
    echo "Simulator log capture is not running."
  fi
}

status_capture() {
  local log_path process_name started_at
  log_path=$(read_meta_value LOG_PATH)
  process_name=$(read_meta_value PROCESS_NAME)
  started_at=$(read_meta_value STARTED_AT)

  if running_pid >/dev/null; then
    echo "running"
    echo "pid=$(running_pid)"
  else
    echo "stopped"
  fi

  [[ -n "$process_name" ]] && echo "process_name=$process_name"
  [[ -n "$started_at" ]] && echo "started_at=$started_at"
  [[ -n "$log_path" ]] && echo "log_path=$log_path"
  echo "launch_agent=$LAUNCH_AGENT_LABEL"
  echo "plist_path=$LAUNCH_AGENT_PLIST"
}

path_capture() {
  local log_path
  log_path=$(read_meta_value LOG_PATH)
  if [[ -z "$log_path" ]]; then
    echo "No simulator log file is registered yet." >&2
    exit 1
  fi
  echo "$log_path"
}

tail_capture() {
  local lines=200
  local follow="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lines)
        lines="${2:-}"
        shift 2
        ;;
      --follow)
        follow="1"
        shift
        ;;
      *)
        echo "Unknown tail option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  local log_path
  log_path=$(read_meta_value LOG_PATH)
  if [[ -z "$log_path" || ! -f "$log_path" ]]; then
    echo "No simulator log file is available yet. Run start first." >&2
    exit 1
  fi

  if [[ "$follow" == "1" ]]; then
    tail -n "$lines" -f "$log_path"
  else
    tail -n "$lines" "$log_path"
  fi
}

stream_capture() {
  local process_name="$DEFAULT_PROCESS_NAME"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --process)
        process_name="${2:-}"
        shift 2
        ;;
      *)
        echo "Unknown stream option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  exec /usr/bin/log stream --style compact --process "$process_name"
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

command="$1"
shift

case "$command" in
  start)
    start_capture "$@"
    ;;
  stop)
    stop_capture
    ;;
  status)
    status_capture
    ;;
  path)
    path_capture
    ;;
  tail)
    tail_capture "$@"
    ;;
  stream)
    stream_capture "$@"
    ;;
  *)
    echo "Unknown command: $command" >&2
    usage >&2
    exit 1
    ;;
esac
