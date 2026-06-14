#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$root/tests/refresh_contract_test.sh"
"$root/tests/enter_zsh_test.sh"
"$root/tests/enter_bash_test.sh"
"$root/tests/enter_fish_test.sh"
"$root/tests/install_test.sh"
"$root/tests/powershell_static_test.sh"

