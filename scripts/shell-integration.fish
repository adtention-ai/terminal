function __adtention_fish_should_trigger_enter --argument-names command_text
    set -l trimmed (string trim -- "$command_text")

    test -n "$trimmed"; or return 1
    string match -q '#*' -- "$trimmed"; and return 1
    string match -qr '^adtention-(open|refresh)([[:space:]]|$)' -- "$trimmed"; and return 1
    string match -qr '^adtention-terminal([[:space:]]|$)' -- "$trimmed"; and return 1

    return 0
end

function __adtention_fish_cache_dir
    if test -n "$ADTENTION_CACHE"
        printf '%s\n' "$ADTENTION_CACHE"
    else
        printf '%s/.adtention/terminal\n' "$HOME"
    end
end

function __adtention_fish_prompt_display --on-event fish_prompt
    set -l cache_dir (__adtention_fish_cache_dir)
    set -l terminal_file "$cache_dir/terminal.txt"

    test -r "$terminal_file"; or return 0
    set -l title_text (sed -n '1p' "$terminal_file" 2>/dev/null)
    set -l line_text (sed -n '2p' "$terminal_file" 2>/dev/null)

    if test -n "$title_text"
        printf '\033]0;%s\007' "$title_text"
    end

    mkdir -p "$cache_dir" 2>/dev/null
    date +%s >"$cache_dir/last_render_seen" 2>/dev/null

    set -l prompt_line_setting "$ADTENTION_PROMPT_LINE"
    if test -z "$prompt_line_setting"
        set prompt_line_setting 1
    end

    if test "$prompt_line_setting" != "0"; and test -n "$line_text"
        printf '%s\n' "$line_text"
    end
end

function __adtention_fish_json_escape --argument-names value
    set -l escaped "$value"
    set escaped (string replace -a '\' '\\' -- "$escaped")
    set escaped (string replace -a '"' '\"' -- "$escaped")
    printf '%s' "$escaped"
end

function __adtention_fish_build_enter_event --argument-names command_text
    set -l cwd (pwd)
    set -l escaped_command (__adtention_fish_json_escape "$command_text")
    set -l escaped_cwd (__adtention_fish_json_escape "$cwd")

    printf '{"source":"terminal-enter","shell":"fish","command":"%s","cwd":"%s"}\n' \
        "$escaped_command" \
        "$escaped_cwd"
end

function __adtention_fish_enter_refresh_async --argument-names command_text
    __adtention_fish_should_trigger_enter "$command_text"; or return 0

    set -l cwd (pwd)
    begin
        __adtention_fish_build_enter_event "$command_text" | command adtention-terminal refresh "$cwd"
    end >/dev/null 2>/dev/null &

    return 0
end

function __adtention_fish_accept_line
    set -l command_text (commandline -b)
    __adtention_fish_enter_refresh_async "$command_text"
    commandline -f execute
end

function __adtention_fish_install_enter_binding
    status is-interactive; or return 0
    bind \r __adtention_fish_accept_line
end

__adtention_fish_install_enter_binding
