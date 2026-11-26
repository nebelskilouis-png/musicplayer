#!/usr/bin/env bash
# Einmalig: Projekt auf GitHub laden + automatischen APK-Build einrichten.
set -e
cd "$HOME/musicplayer"
export PATH="$HOME/snap/flutter/common/flutter/bin:/snap/bin:$PATH"

echo "== 1/5 git + gh installieren (Passwort nötig) =="
command -v git >/dev/null && command -v gh >/dev/null || sudo apt install -y git gh

echo "== 2/5 Flutter-Version merken =="
mkdir -p .github/workflows
cp ci/build-apk.yml .github/workflows/build-apk.yml
FV=$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')
echo "${FV:-stable}" > .github/flutter_version.txt
echo "Flutter: ${FV}"

echo "== 3/5 git-Repo anlegen =="
[ -d .git ] || git init -b main
git config user.name  >/dev/null || git config user.name  "louis"
git config user.email >/dev/null || git config user.email "louis@localhost"
git add -A
git commit -qm "Musicplayer: Stand vom PC" || true

echo "== 4/5 GitHub-Login (Browser öffnet sich / Code eingeben) =="
gh auth status >/dev/null 2>&1 || gh auth login --hostname github.com --git-protocol https --web

echo "== 5/5 Privates Repo erstellen + hochladen =="
gh repo view musicplayer >/dev/null 2>&1 || gh repo create musicplayer --private --source=. --remote=origin
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$(gh api user -q .login)/musicplayer.git"
gh auth setup-git
if [ -f "$HOME/.android/debug.keystore" ]; then
  base64 -w0 "$HOME/.android/debug.keystore" | gh secret set DEBUG_KEYSTORE -R "$(gh api user -q .login)/musicplayer"
else
  echo "WARNUNG: ~/.android/debug.keystore fehlt – APK hat andere Signatur."
fi
git push -u origin main

U=$(gh api user -q .login)
echo
echo "FERTIG. APK in ~10 Min hier (am Handy öffnen, bei GitHub eingeloggt):"
echo "  https://github.com/$U/musicplayer/releases/latest"
