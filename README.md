# ADtention Terminal

ADtention Terminal shows sponsor text above normal shell prompts and refreshes
that sponsor only after a human presses Enter on a real command.

Example terminal behavior:

```text
⊕ $0.42  Alchemy: APIs for every chain -> learn-more
julian@mac app % npm test
```

The Enter wrapper starts a background refresh and then lets the original command
run normally. The next prompt renders the cached sponsor line.

Run `learn-more` to open the current sponsor page.
The shell integration also runs `adtention-terminal update` quietly in the
background whenever a terminal opens. Run it manually to update immediately.

## Supported Shells

- zsh: Enter wrapper enabled by default.
- fish: Enter wrapper enabled by default when the integration is sourced.
- PowerShell: Enter wrapper enabled through PSReadLine when available.
- bash: prompt display works by default; Enter wrapping is experimental and
  requires `ADTENTION_BASH_ENTER_EXPERIMENTAL=1`.

## Install

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/adtention-ai/terminal/main/install.sh | sh
```

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/adtention-ai/terminal/main/install.ps1 | iex
```

The shell integration writes managed blocks to shell profile files and can be
run more than once without duplicating those blocks.

## Shared State

ADtention Terminal shares account state with the Claude and Codex products.
When `~/.claude/adtention` exists, Terminal uses it. Otherwise it uses
`~/.adtention`. Legacy `~/.codex/adtention` state is copied into the shared
cache without overwriting an existing `identity.json`.

## Test

```sh
./test.sh
```

The tests use fake clients and local cache directories. They do not call the
ADtention API.

## Release Build

Build all release binaries and checksums:

```sh
./build.sh
cd bin && shasum -a 256 -c SHA256SUMS
```

Tagged releases publish the same platform binaries, the runtime package, and
the bootstrap installer. The tag must match `client/Cargo.toml`, for example
`v1.0.1`.
