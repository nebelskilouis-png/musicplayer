#!/usr/bin/env bash
# Läuft jede Minute (cron). Lädt Änderungen automatisch zu GitHub hoch,
# sobald seit 2 Minuten nichts mehr geändert wurde. GitHub baut dann die APK.
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
cd "$HOME/musicplayer" || exit 0
exec 9>/tmp/musicplayer_autopush.lock; flock -n 9 || exit 0

# Workflow-Vorlage übernehmen (Claude darf .github nicht direkt schreiben)
if [ -f ci/build-apk.yml ] && ! cmp -s ci/build-apk.yml .github/workflows/build-apk.yml; then
  mkdir -p .github/workflows && cp ci/build-apk.yml .github/workflows/build-apk.yml
fi

CHANGED=$(git ls-files -m -o --exclude-standard)
[ -z "$CHANGED" ] && exit 0

# Noch in Arbeit? (letzte Änderung jünger als 2 Minuten)
NOW=$(date +%s)
while IFS= read -r f; do
  [ -e "$f" ] || continue
  M=$(stat -c %Y "$f")
  [ $((NOW - M)) -lt 120 ] && exit 0
done <<< "$CHANGED"

MSG="Update $(date '+%d.%m. %H:%M')"
[ -f .commit_msg ] && MSG=$(cat .commit_msg) && rm -f .commit_msg
git add -A && git commit -qm "$MSG" && git push -q && echo "$(date) gepusht: $MSG"
