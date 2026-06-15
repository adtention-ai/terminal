__adtention_cache_dir() {
  if [[ -n "${ADTENTION_CACHE:-}" ]]; then
    print -r -- "$ADTENTION_CACHE"
  elif [[ -n "${ADTENTION_CACHE_DIR:-}" ]]; then
    print -r -- "$ADTENTION_CACHE_DIR"
  elif [[ -d "$HOME/.claude/adtention" || -f "$HOME/.claude/adtention/identity.json" ]]; then
    print -r -- "$HOME/.claude/adtention"
  else
    print -r -- "$HOME/.adtention"
  fi
}

__adtention_trim_left() {
  local text="$1"
  text="${text#${text%%[![:space:]]*}}"
  print -r -- "$text"
}

__adtention_should_trigger_enter() {
  local command_text="$(__adtention_trim_left "$1")"
  local first_word

  [[ -n "$command_text" ]] || return 1
  [[ "$command_text" != \#* ]] || return 1

  first_word="${command_text%%[[:space:]]*}"
  case "$first_word" in
    adtention|adtention-*|adtention-terminal)
      return 1
      ;;
    learn-more)
      return 1
      ;;
  esac

  return 0
}

learn-more() {
  adtention-terminal learn-more "$@"
}

__adtention_update_async() {
  [[ "${ADTENTION_AUTO_UPDATE:-1}" != "0" ]] || return 0

  {
    command adtention-terminal update </dev/null
  } >/dev/null 2>&1 &!
}

__adtention_json_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"

  print -r -- "$value"
}

__adtention_build_enter_event() {
  local command_text="$1"
  local escaped_command escaped_cwd

  escaped_command="$(__adtention_json_escape "$command_text")"
  escaped_cwd="$(__adtention_json_escape "$PWD")"

  printf '{"source":"terminal-enter","shell":"zsh","command":"%s","cwd":"%s"}\n' \
    "$escaped_command" \
    "$escaped_cwd"
}

__adtention_enter_refresh_async() {
  local command_text="$1"
  local cwd="$PWD"

  __adtention_should_trigger_enter "$command_text" || return 0

  {
    __adtention_build_enter_event "$command_text" | adtention-terminal refresh "$cwd"
  } >/dev/null 2>&1 &!
}

__adtention_accept_line() {
  local command_text="$BUFFER"

  __adtention_enter_refresh_async "$command_text" >/dev/null 2>&1 || true
  zle .accept-line
}

__adtention_display_cache() {
  local cache_dir="$(__adtention_cache_dir)"
  local terminal_file="$cache_dir/terminal.txt"
  local title_text line_text now

  [[ -r "$terminal_file" ]] || return 0

  {
    IFS= read -r title_text || title_text=""
    IFS= read -r line_text || line_text=""
  } <"$terminal_file"

  [[ -n "$title_text$line_text" ]] || return 0

  if [[ -n "$title_text" ]]; then
    print -n -- $'\e]0;'
    print -n -- "$title_text"
    print -n -- $'\a'
  fi

  mkdir -p "$cache_dir" 2>/dev/null || true
  now="$(date +%s 2>/dev/null || print -r -- "")"
  print -r -- "$now" >"$cache_dir/last_render_seen" 2>/dev/null || true

  if [[ "${ADTENTION_PROMPT_LINE:-1}" != "0" && -n "$line_text" ]]; then
    print -r -- "$line_text"
  fi
}

__adtention_precmd() {
  __adtention_display_cache
}

autoload -Uz add-zsh-hook
add-zsh-hook -d precmd __adtention_precmd 2>/dev/null || true
add-zsh-hook precmd __adtention_precmd 2>/dev/null || true

__adtention_update_async
zle -N accept-line __adtention_accept_line 2>/dev/null || true
