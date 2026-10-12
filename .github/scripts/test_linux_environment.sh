#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0

work_dir="$(mktemp -d /tmp/nanotateczki-linux-env-build.XXXXXX)"
trap 'rm -f "$work_dir/linux_environment_test"; rmdir "$work_dir"' EXIT

read -r -a glib_flags <<< "$(pkg-config --cflags --libs glib-2.0)"
"${CXX:-c++}" -std=c++14 -Wall -Wextra -Werror \
  test/linux/linux_environment_test.cc linux/runner/linux_environment.cc \
  "${glib_flags[@]}" -o "$work_dir/linux_environment_test"
"$work_dir/linux_environment_test" "$@"
