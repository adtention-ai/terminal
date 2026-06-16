#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$root/tests/refresh_contract_test.sh"
"$root/tests/cache_migration_test.sh"
"$root/tests/release_files_test.sh"
"$root/tests/bootstrap_install_test.sh"
"$root/tests/bootstrap_install_ps1_test.sh"
"$root/tests/learn_more_test.sh"
"$root/tests/update_test.sh"
"$root/tests/enter_zsh_test.sh"
"$root/tests/enter_bash_test.sh"
"$root/tests/enter_fish_test.sh"
"$root/tests/install_test.sh"
"$root/tests/powershell_static_test.sh"
