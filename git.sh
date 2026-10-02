#!/bin/bash

BRANCH="dev"
REMOTE="origin"

MAGENTA="\033[0;35m"
GREEN="\033[0;32m"
RESET="\033[0m"

while true; do
    echo "Sprawdzam origin/dev..."

    # Pobiera tylko informacje o nowych commitach
    git fetch "$REMOTE" "$BRANCH"

    LOCAL=$(git rev-parse "$BRANCH")
    REMOTE_COMMIT=$(git rev-parse "$REMOTE/$BRANCH")

    if [ "$LOCAL" = "$REMOTE_COMMIT" ]; then
        
    else
        

        # sprawdzenie czy lokalny dev jest tylko za origin/dev
        BEHIND=$(git rev-list --count "$BRANCH..$REMOTE/$BRANCH")

        if [ "$BEHIND" -gt 0 ]; then
            

            git switch "$BRANCH"
            git pull --ff-only "$REMOTE" "$BRANCH"

            echo -e "${GREEN}DEV zaktualizowany.${RESET}"
        else
            echo -e "${MAGENTA}Lokalny DEV ma własne zmiany/commity. Nie robię automatycznego pulla.${RESET}"
        fi
    fi

    echo "Następne sprawdzenie za 60 s..."
    sleep 30
done