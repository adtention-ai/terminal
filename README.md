# ADtention Terminal

ADtention Terminal shows sponsor text above normal shell prompts and refreshes
that sponsor only after a human presses Enter on a real command.

Example terminal behavior:

```text
⊕ $0.42  Alchemy: APIs for every chain -> alchemy.com
julian@mac app % npm test
```

The Enter wrapper starts a background refresh and then lets the original command
run normally. The next prompt renders the cached sponsor line.

## Supported Shells

- zsh: Enter wrapper enabled by default.
- fish: Enter wrapper enabled by default when the integration is sourced.
- PowerShell: Enter wrapper enabled through PSReadLine when available.
- bash: prompt display works by default; Enter wrapping is experimental and
  requires `ADTENTION_BASH_ENTER_EXPERIMENTAL=1`.

## Install

macOS/Linux:

```sh
scripts/install-shell-integration.sh
```

Windows PowerShell:

```powershell
.\scripts\install-shell-integration.ps1
```

The shell integration writes managed blocks to shell profile files and can be
run more than once without duplicating those blocks.

## Test

```sh
./test.sh
```

The tests use fake clients and local cache directories. They do not call the
ADtention API.
