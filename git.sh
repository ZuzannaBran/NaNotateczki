#!/bin/bash

BRANCH="dev"
REMOTE="origin"
INTERVAL=30

MAGENTA="\033[0;35m"
GREEN="\033[0;32m"
RESET="\033[0m"

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
