# ADtention Terminal TDD Plan

## Goal

Build ADtention for normal terminals by reusing the Codex cache, render, and refresh model, but replace the Codex hook with an Enter-key trigger.

In plain terms: when a human presses Enter to run a command, our shell integration briefly records that local event, starts a background refresh, and then lets the shell run the command exactly as usual. The Enter wrapper must never make the terminal feel slower or break normal command execution.

## Product Rules

- A refresh is triggered only by a human pressing Enter in an interactive shell.
- Empty lines, whitespace-only lines, and comments do not trigger refresh.
- ADtention's own commands, such as `adtention-open` and `adtention-refresh`, do not trigger refresh.
- The shell command text is used only locally for category classification.
- The network `/v1/serve` payload must not include the raw command, cwd, file names, or repo names.
- If the refresh path fails, the original command still runs.
- Refresh still requires a recent render heartbeat, using the same idea as `last_render_seen`.
- Refresh still respects a minimum dwell window, using the same idea as `last_serve`.
- The visible prompt/title path remains cache-only and does not call the network.

## Starting Point From `../adtention-codex`

Reusable parts:

- Rust cache/render/refresh logic from `plugins/adtention-codex/client`.
- Cache files such as `terminal.txt`, `prompt_line.txt`, `current_ad.txt`, `current_click.txt`, `last_render_seen`, and `last_serve`.
- Shell display logic that prints the prompt line and updates the terminal title.
- `adtention-open` behavior.

Parts to replace:

- Codex plugin install.
- Codex `UserPromptSubmit` hook.
- Codex-specific hook JSON fields.
- Codex-branded binary, path, and environment names where practical.

## Proposed File Shape

```text
client/
  Cargo.toml
  src/
    main.rs
    lib.rs
scripts/
  shell-integration.zsh
  shell-integration.bash
  shell-integration.fish
  shell-integration.ps1
  install-shell-integration.sh
  install-shell-integration.ps1
tests/
  enter_zsh_test.sh
  enter_bash_test.sh
  refresh_contract_test.sh
  install_test.sh
```

## TDD Phase 1: Refresh Contract

First write tests for the behavior that must stay true no matter which shell triggers it.

Tests:

- `refresh skips when last_render_seen is missing`
- `refresh skips when last_render_seen is too old`
- `refresh skips inside dwell window`
- `refresh serves when render is fresh and dwell passed`
- `serve payload contains publisher_id, category, nonce`
- `serve payload does not contain command, cwd, file names, or repo names`
- `ad text with terminal control characters is sanitized before cache write`
- `open resolves cached relative click URL safely`

Implementation target:

- Port the reusable Rust core from `../adtention-codex`.
- Add a terminal event input shape:

```json
{
  "source": "terminal-enter",
  "shell": "zsh",
  "command": "npm test",
  "cwd": "/local/path"
}
```

Important: this JSON is local input to the client. The server still receives only the broad category, anonymous publisher id, and nonce.

## TDD Phase 2: Local Command Classification

Write tests before implementing the classifier.

Tests:

- `npm test` -> `web`
- `pnpm dev` -> `web`
- `vite build` -> `web`
- `docker build .` -> `devops`
- `kubectl get pods` -> `devops`
- `terraform plan` -> `devops`
- `cargo test` -> `systems`
- `go test ./...` -> `systems`
- `python train.py` -> `data`
- `pytest` -> `data`
- `forge test` -> `web3`
- `hardhat test` -> `web3`
- unknown command falls back to folder classification

Implementation target:

- Add a local `classify_terminal_command` function.
- Keep folder classification as fallback.
- Keep prompt/transcript classification out of the terminal product unless a future feature explicitly needs it.

## TDD Phase 3: Zsh Enter Wrapper

Zsh is the first shell to implement because it has a clean line-editor system called ZLE. ZLE is the part of zsh that owns the editable command line before the shell runs it.

Write pure shell function tests first:

- `__adtention_should_trigger_enter ""` returns false
- `__adtention_should_trigger_enter "   "` returns false
- `__adtention_should_trigger_enter "# comment"` returns false
- `__adtention_should_trigger_enter "adtention-open"` returns false
- `__adtention_should_trigger_enter "npm test"` returns true
- `__adtention_build_enter_event "npm test"` includes source, shell, command, and cwd
- `__adtention_enter_refresh_async` calls the client in the background

Then write an interactive zsh test using `zpty` if available:

- Start `zsh -f`
- Source `scripts/shell-integration.zsh`
- Type `echo hello` and press Enter
- Assert `hello` still prints
- Assert the fake client received one `refresh` call
- Assert pressing Enter on an empty line does not call refresh

Implementation target:

```sh
__adtention_accept_line() {
  local command_text="$BUFFER"
  __adtention_enter_event "$command_text" >/dev/null 2>&1 &
  zle .accept-line
}

zle -N accept-line __adtention_accept_line
```

The key point is that `zle .accept-line` calls the original Enter behavior. Our wrapper must always end by handing control back to the shell.

## TDD Phase 4: Prompt Display

Write tests for the visible side.

Tests:

- Prompt display reads `terminal.txt`.
- Prompt display updates the terminal title.
- Prompt display prints the prompt line when `ADTENTION_PROMPT_LINE` is not `0`.
- Prompt display does not print the prompt line when `ADTENTION_PROMPT_LINE=0`.
- Prompt display writes `last_render_seen`.
- Prompt display makes no network calls.

Implementation target:

- Port and rename the existing display hook.
- Use `precmd` in zsh for prompt display.
- Keep display and refresh separate: display reads cache, Enter wrapper triggers refresh.

## TDD Phase 5: Bash Proof

Bash Enter wrapping is trickier than zsh. The test should prove the exact keybinding before we ship it.

Candidate design:

- Bind a hidden readline key sequence to a shell function with `bind -x`.
- Bind Enter to a readline macro that first runs that hidden sequence, then performs the normal accept-line action.

Tests:

- Interactive bash can still run `echo hello`.
- Fake client receives one refresh after Enter.
- Empty Enter does not refresh.
- Ctrl-J and Enter do not cause duplicate refreshes.
- If the ADtention shell function errors, the command still runs.

Decision rule:

- If Bash cannot pass these tests reliably, do not fake it.
- Ship zsh first and keep Bash behind an explicit experimental flag.

## TDD Phase 6: Fish And PowerShell

Fish tests:

- Bind Enter to capture `commandline -b`.
- Then call fish's normal execute behavior.
- Prove command execution still works.

PowerShell tests:

- Use `Set-PSReadLineKeyHandler -Key Enter`.
- Capture the current line.
- Call `[Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()`.
- Prove command execution still works.

These shells can follow after the zsh proof because their implementation details are different.

## TDD Phase 7: Installer

Tests:

- Installer writes one managed block into `.zshrc`.
- Running installer twice does not duplicate the block.
- Installer can uninstall the block.
- Installer respects `ADTENTION_INSTALL_ROOT`.
- Installer respects `ADTENTION_CACHE`.
- Installer does not require Codex.
- Installer does not call `codex plugin ...`.

Implementation target:

- Root install script for macOS/Linux.
- PowerShell install script for Windows.
- No Codex plugin marketplace setup.

## TDD Phase 8: Diagnostics

Tests:

- Diagnostic reports shell integration installed or missing.
- Diagnostic reports client binary found or missing.
- Diagnostic reports cache path.
- Diagnostic reports last render age.
- Diagnostic reports last serve age.
- Diagnostic reports last skipped reason.
- Diagnostic never prints private command text by default.

Implementation target:

- `adtention doctor`
- Optional `ADTENTION_DEBUG=1` can show local command-event details for development.

## Acceptance Criteria For V1

- zsh Enter wrapping works in an interactive terminal.
- Pressing Enter on a real command triggers exactly one background refresh attempt.
- The command still runs even if ADtention is broken.
- Prompt display reads local cache only.
- Server payload never includes raw command text.
- Install and uninstall are idempotent.
- Tests can run locally with one command.

## Suggested First Implementation Slice

1. Port the Rust client and tests from `../adtention-codex`.
2. Add terminal event classification tests.
3. Add zsh shell function unit tests.
4. Add zsh interactive Enter test.
5. Implement only enough code to make those tests pass.
6. Refactor names from `adtention-codex` to `adtention-terminal`.
7. Add installer tests after the zsh behavior is proven.

