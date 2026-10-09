#!/usr/bin/env bash

BRANCH="dev"
REMOTE="origin"
INTERVAL=30

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUNTIME_DIR="$PROJECT_DIR/.dart_tool"
FLUTTER_PID_FILE="$RUNTIME_DIR/flutter-run.pid"
FLUTTER_LAUNCHER_PID_FILE="$RUNTIME_DIR/flutter-run-launcher.pid"

MAGENTA="\033[0;35m"
GREEN="\033[0;32m"
RESET="\033[0m"

run_flutter_app() {
    cd "$PROJECT_DIR" || exit 1
    mkdir -p -- "$RUNTIME_DIR" || exit 1

    if ! printf '%s\n' "$$" > "$FLUTTER_LAUNCHER_PID_FILE"; then
        echo "Nie udało się zapisać PID-u procesu uruchamiającego."
        exit 1
    fi
    trap 'rm -f -- "$FLUTTER_LAUNCHER_PID_FILE"' EXIT

    flutter run -d linux --pid-file "$FLUTTER_PID_FILE"
}

read_pid() {
    local pid_file=$1
    local pid

    [ -r "$pid_file" ] || return 1
    read -r pid < "$pid_file"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    printf '%s\n' "$pid"
}

managed_flutter_pid() {
    local pid
    local argument
    local has_flutter_tool=false
    local has_pid_file=false

    pid=$(read_pid "$FLUTTER_PID_FILE") || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1

    while IFS= read -r -d '' argument; do
        if [[ "$argument" == *flutter_tools.snapshot ]]; then
            has_flutter_tool=true
        elif [ "$argument" = "$FLUTTER_PID_FILE" ] ||
            [ "$argument" = "--pid-file=$FLUTTER_PID_FILE" ]; then
            has_pid_file=true
        fi
    done < "/proc/$pid/cmdline"

    [ "$has_flutter_tool" = true ] && [ "$has_pid_file" = true ] || return 1
    printf '%s\n' "$pid"
}

launch_flutter_terminal() {
    mkdir -p -- "$RUNTIME_DIR" || return 1
    rm -f -- "$FLUTTER_PID_FILE" "$FLUTTER_LAUNCHER_PID_FILE"

    if command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal \
            --title="NaNotateczki - flutter run" \
            --working-directory="$PROJECT_DIR" \
            -- "$PROJECT_DIR/git.sh" --run-app
    elif command -v x-terminal-emulator >/dev/null 2>&1; then
        x-terminal-emulator \
            -T "NaNotateczki - flutter run" \
            -e "$PROJECT_DIR/git.sh" --run-app
    else
        echo -e "${MAGENTA}Nie znaleziono obsługiwanego terminala.${RESET}"
        echo "Uruchom ręcznie: flutter run -d linux"
        return 1
    fi

    echo -e "${GREEN}Uruchamiam aplikację w drugim terminalu.${RESET}"
}

start_or_restart_flutter() {
    local flutter_pid

    if flutter_pid=$(managed_flutter_pid); then
        if kill -USR2 "$flutter_pid"; then
            echo -e "${GREEN}Wysłano R (hot restart) do działającej" \
                "aplikacji.${RESET}"
        else
            echo -e "${MAGENTA}Nie udało się zrestartować aplikacji.${RESET}"
        fi
        return
    fi

    if read_pid "$FLUTTER_LAUNCHER_PID_FILE" >/dev/null; then
        echo -e "${MAGENTA}Aplikacja nadal się uruchamia;" \
            "pomijam drugą instancję.${RESET}"
        return
    fi

    launch_flutter_terminal
}

if [ "${1:-}" = "--run-app" ]; then
    run_flutter_app
    exit $?
fi

cd "$PROJECT_DIR" || exit 1

while true; do
    echo "Sprawdzam $REMOTE/$BRANCH..."

    # Odśwież remote-tracking branch origin/dev.
    if ! git fetch "$REMOTE" "$BRANCH:refs/remotes/$REMOTE/$BRANCH"; then
        echo -e "${MAGENTA}Nie udało się pobrać $REMOTE/$BRANCH.${RESET}"
        echo "Następne sprawdzenie za ${INTERVAL} s..."
        sleep "$INTERVAL"
        continue
    fi

    if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        echo -e "${MAGENTA}Lokalna gałąź $BRANCH nie istnieje.${RESET}"
        echo "Następne sprawdzenie za ${INTERVAL} s..."
        sleep "$INTERVAL"
        continue
    fi

    LOCAL_COMMIT=$(git rev-parse "refs/heads/$BRANCH")
    REMOTE_COMMIT=$(git rev-parse "refs/remotes/$REMOTE/$BRANCH")

    if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
        echo -e "${GREEN}DEV jest aktualny.${RESET}"
    else
        read -r AHEAD BEHIND < <(
            git rev-list --left-right --count "$BRANCH...$REMOTE/$BRANCH"
        )

        if [ "$AHEAD" -eq 0 ] && [ "$BEHIND" -gt 0 ]; then
            if [ -n "$(git status --porcelain)" ]; then
                echo -e "${MAGENTA}Są lokalne niezapisane zmiany. Nie robię automatycznego pulla.${RESET}"
            elif git switch "$BRANCH" && git pull --ff-only "$REMOTE" "$BRANCH"; then
                echo -e "${GREEN}DEV zaktualizowany o $BEHIND commit(y).${RESET}"
                start_or_restart_flutter
            else
                echo -e "${MAGENTA}Aktualizacja DEV nie powiodła się.${RESET}"
            fi
        elif [ "$AHEAD" -gt 0 ] && [ "$BEHIND" -eq 0 ]; then
            echo -e "${MAGENTA}Lokalny DEV ma $AHEAD własny(e) commit(y). Nie robię pulla.${RESET}"
        else
            echo -e "${MAGENTA}Lokalny DEV i origin/dev rozjechały się (local +$AHEAD, remote +$BEHIND). Nie robię pulla.${RESET}"
        fi
    fi

    echo "Następne sprawdzenie za ${INTERVAL} s..."
    sleep "$INTERVAL"
done
