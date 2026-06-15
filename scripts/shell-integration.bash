# Bash Enter wrapping is experimental because Readline does not expose a clean
# "run this, then accept the line" hook. Enable with ADTENTION_BASH_ENTER_EXPERIMENTAL=1.

__adtention_cache_dir() {
  if [[ -n "${ADTENTION_CACHE:-}" ]]; then
    printf '%s\n' "$ADTENTION_CACHE"
  elif [[ -d "$HOME/.claude/adtention" || -f "$HOME/.claude/adtention/identity.json" ]]; then
    printf '%s/.claude/adtention\n' "$HOME"
  else
    printf '%s/.adtention\n' "$HOME"
  fi
}

__adtention_trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

__adtention_prompt_display() {
  local cache_dir terminal_file title_text line_text now
  cache_dir="$(__adtention_cache_dir)"
  terminal_file="$cache_dir/terminal.txt"

  [[ -r "$terminal_file" ]] || return 0
  {
    IFS= read -r title_text || title_text=""
    IFS= read -r line_text || line_text=""
  } <"$terminal_file"

  [[ -n "$title_text$line_text" ]] || return 0

  if [[ -n "$title_text" ]]; then
    printf '\033]0;%s\007' "$title_text"
  fi

  mkdir -p "$cache_dir" 2>/dev/null || true
  now="$(date +%s 2>/dev/null || printf '')"
  printf '%s\n' "$now" >"$cache_dir/last_render_seen" 2>/dev/null || true

  if [[ "${ADTENTION_PROMPT_LINE:-1}" != "0" && -n "$line_text" ]]; then
    printf '%s\n' "$line_text"
  fi
}

__adtention_install_prompt_display() {
  [[ $- == *i* ]] || return 0
  case ";${PROMPT_COMMAND:-};" in
    *";__adtention_prompt_display;"*) ;;
    *) PROMPT_COMMAND="__adtention_prompt_display${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
}

__adtention_should_trigger_enter() {
  local trimmed
  trimmed="$(__adtention_trim "${1-}")"

  [[ -n "$trimmed" ]] || return 1
  [[ "$trimmed" != \#* ]] || return 1

  case "$trimmed" in
    adtention-open | adtention-open[[:space:]]* | \
      adtention-refresh | adtention-refresh[[:space:]]* | \
      adtention-terminal | adtention-terminal[[:space:]]* | \
      learn-more | learn-more[[:space:]]*)
      return 1
      ;;
  esac

  return 0
}

learn-more() {
  command adtention-terminal learn-more "$@"
}

__adtention_update_async() {
  [[ "${ADTENTION_AUTO_UPDATE:-1}" != "0" ]] || return 0

  (
    command adtention-terminal update </dev/null
  ) >/dev/null 2>&1 &

  return 0
}

__adtention_json_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

__adtention_build_enter_event() {
  local command_text="${1-}"
  local cwd
  local escaped_command
  local escaped_cwd

  cwd="$(pwd 2>/dev/null || printf '%s' "${PWD:-}")"
  escaped_command="$(__adtention_json_escape "$command_text")"
  escaped_cwd="$(__adtention_json_escape "$cwd")"

  printf '{"source":"terminal-enter","shell":"bash","command":"%s","cwd":"%s"}\n' \
    "$escaped_command" \
    "$escaped_cwd"
}

__adtention_enter_refresh_async() {
  local command_text="${1-}"
  local cwd

  __adtention_should_trigger_enter "$command_text" || return 0

  cwd="$(pwd 2>/dev/null || printf '%s' "${PWD:-}")"
  (
    __adtention_build_enter_event "$command_text" | command adtention-terminal refresh "$cwd"
  ) >/dev/null 2>&1 &

  return 0
}

__adtention_bash_enter_hook() {
  __adtention_enter_refresh_async "${READLINE_LINE-}"
  return 0
}

__adtention_install_bash_enter_binding() {
  [[ $- == *i* ]] || return 0
  [[ "${ADTENTION_BASH_ENTER_EXPERIMENTAL:-0}" == "1" ]] || return 0

  bind -x '"\C-x\C-a": __adtention_bash_enter_hook' 2>/dev/null || return 0
  bind '"\C-m": "\C-x\C-a\C-j"' 2>/dev/null || return 0
}

__adtention_update_async
__adtention_install_prompt_display
__adtention_install_bash_enter_binding
