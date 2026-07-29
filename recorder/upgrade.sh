#!/usr/bin/env bash
#
# Sermony.Recorder — Update eines laufenden Deployments.
#
#   ./scripts/upgrade.sh            → Bundle aktualisieren + .env-Reconcile + Image-Pull + Neustart
#   ./scripts/upgrade.sh --prune    → zusätzlich alte Images aufräumen
#
# Bundle-Update — zwei Modi, automatisch erkannt:
#   • Git-Clone  (.git vorhanden)  → git pull --ff-only         (Maintainer)
#   • Tarball    (kein .git)       → neuestes Gitea-Release ziehen und
#                                    deploy/+scripts/ ersetzen   (Kunde)
# In beiden Fällen bleibt deploy/.env unangetastet und das Image kommt aus der
# Registry (docker compose pull).
#
# .env-Reconcile: Keys, die in deploy/.env.example NEU dazugekommen sind, werden
# mit ihrem Beispiel-Default an deploy/.env angehängt (bestehende Werte werden
# NIE überschrieben). Bewusst gegen die .env.example statt gegen das Compose
# reconciled — kein YAML-Parsing, keine ${VAR:-default}-Escapes nötig.
#
# Release-Quelle: Default ist das ÖFFENTLICHE GitHub-Dist-Repo
# (github.com/sermony/sermony-selfhosted — dorthin published die CI das Bundle;
# das Gitea-Quell-Repo ist privat und für Kunden nicht erreichbar).
# Überschreiben für privates/gespiegeltes Repo:
#   SERMONY_RELEASE_API=https://<host>/api/v1/repos/<owner>/<repo>  (Gitea)
#                       bzw. https://api.github.com/repos/<owner>/<repo>
#   RELEASE_TOKEN=<token>   (nur falls das Repo nicht öffentlich ist)
#
# Muster analog Sermony.Web scripts/upgrade.sh.

# Unter sh/dash gestartet (z.B. `sh upgrade.sh`)? → mit bash re-execen; das Skript
# nutzt Bash-Features (pipefail, [[ ]], Arrays) und bricht unter dash sonst
# mit "set: Illegal option -o pipefail".
if [ -z "${BASH_VERSION:-}" ]; then
  command -v bash >/dev/null 2>&1 || { echo "FEHLER: bash wird benötigt." >&2; exit 1; }
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Zwei Layouts, automatisch erkannt:
#   • Git-Clone:       <repo>/scripts/upgrade.sh + <repo>/deploy/   (Maintainer)
#   • Release-Bundle:  alles flach neben upgrade.sh, z.B. /opt/sermony-recorder/  (Kunde)
if [[ -d "$SCRIPT_DIR/../deploy" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  DEPLOY_DIR="$REPO_ROOT/deploy"
else
  REPO_ROOT="$SCRIPT_DIR"
  DEPLOY_DIR="$SCRIPT_DIR"
fi
ENV_FILE="$DEPLOY_DIR/.env"
ENV_EXAMPLE="$DEPLOY_DIR/.env.example"

c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

PRUNE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prune) PRUNE=1; shift ;;
    -h|--help) echo "Verwendung: $0 [--prune]"; exit 0 ;;
    *) c_red "Unbekannte Option: $1"; exit 2 ;;
  esac
done

[[ -f "$ENV_FILE" ]] || { c_red "$ENV_FILE fehlt — zuerst setup.sh ausführen."; exit 1; }

RELEASE_API="${SERMONY_RELEASE_API:-https://api.github.com/repos/sermony/sermony-selfhosted}"

# Tarball-Update: neuestes Gitea-Release ziehen und Compose/.env.example/Skripte
# ersetzen. Die .env wird NIE angefasst (nicht im Bundle). Das Bundle ist FLACH
# (setup.sh/upgrade.sh/docker-compose.yml/.env.example im Root — Layout
# /opt/sermony-recorder). Dateien werden via mv (rename)
# ersetzt — nicht cp: cp würde die gerade laufende upgrade.sh in-place truncaten;
# rename tauscht nur den Verzeichniseintrag, der laufende Prozess behält sein Inode.
update_from_release() {
  command -v curl >/dev/null 2>&1 || { c_red "curl wird für Tarball-Updates benötigt."; exit 1; }
  local hdr=(); [[ -n "${RELEASE_TOKEN:-}" ]] && hdr=(-H "Authorization: token ${RELEASE_TOKEN}")
  # Release-LISTE statt /latest: im Dist-Repo (sermony-selfhosted) können auch
  # Nicht-Recorder-Releases liegen — wir greifen das neueste Release, das ein
  # sermony-recorder-Asset trägt (Liste ist neueste-zuerst; ?per_page versteht
  # GitHub, Gitea ignoriert den Param und liefert ebenfalls neueste-zuerst).
  # Gezielt das Bundle-Asset (sermony-recorder-…) greifen — NICHT ein
  # automatisch angehängtes Source-Archiv (…/archive/….tar.gz).
  c_green "Suche neuestes Recorder-Release: ${RELEASE_API}/releases"
  local url
  url="$(curl -fsSL "${hdr[@]}" "${RELEASE_API}/releases?per_page=20" \
         | grep -oE 'https?://[^"]+sermony-recorder-[^"]+\.tar\.gz' | grep -v '/archive/' | head -n1 || true)"
  [[ -n "$url" ]] || { c_red "Kein Release-Bundle gefunden (privates Repo? RELEASE_TOKEN setzen)."; exit 1; }
  c_green "Lade Bundle: $url"

  local tmp="$REPO_ROOT/.upgrade.tmp"   # gleiche Partition wie SCRIPT_DIR → mv = rename
  rm -rf "$tmp"; mkdir -p "$tmp"
  curl -fsSL "${hdr[@]}" "$url" -o "$tmp/bundle.tar.gz"
  tar -xzf "$tmp/bundle.tar.gz" -C "$tmp"

  [[ -f "$tmp/docker-compose.yml" ]] && mv -f "$tmp/docker-compose.yml" "$DEPLOY_DIR/docker-compose.yml"
  [[ -f "$tmp/.env.example" ]]        && mv -f "$tmp/.env.example"        "$ENV_EXAMPLE"
  [[ -f "$tmp/README.md" ]]           && mv -f "$tmp/README.md"           "$REPO_ROOT/README.md"
  local f
  for f in "$tmp"/*.sh; do
    [[ -e "$f" ]] && mv -f "$f" "$SCRIPT_DIR/$(basename "$f")"
  done
  chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
  rm -rf "$tmp"
  c_green "Deploy-Bundle aus Release aktualisiert."
}

# ── Bundle aktualisieren (Compose-Datei, Scripts) ─────────────────────────────
if [[ -d "$REPO_ROOT/.git" ]] && command -v git >/dev/null 2>&1; then
  c_green "Git-Clone erkannt — aktualisiere via git pull..."
  git -C "$REPO_ROOT" pull --ff-only || {
    c_red "git pull fehlgeschlagen (lokale Änderungen?). Bitte manuell auflösen."; exit 1; }
else
  c_yellow "Kein Git-Repo — aktualisiere via Gitea-Release-Tarball."
  update_from_release
fi

# ── .env-Reconcile: neue Keys aus .env.example nachtragen ─────────────────────
if [[ -f "$ENV_EXAMPLE" ]]; then
  ADDED=0
  while IFS= read -r line; do
    # Nur KEY=VALUE-Zeilen (keine Kommentare/Leerzeilen)
    [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
    key="${line%%=*}"
    if ! grep -qE "^${key}=" "$ENV_FILE"; then
      if [[ $ADDED -eq 0 ]]; then
        printf '\n# ── Neu seit Upgrade am %s (Defaults aus .env.example) ──\n' "$(date -Iseconds)" >> "$ENV_FILE"
      fi
      printf '%s\n' "$line" >> "$ENV_FILE"
      c_yellow "Neuer Konfig-Key nachgetragen: $key (Default aus .env.example — bei Bedarf anpassen)"
      ADDED=1
    fi
  done < "$ENV_EXAMPLE"
  [[ $ADDED -eq 0 ]] && c_green ".env ist vollständig — keine neuen Keys."
fi

# ── Pickup-Ordner für Display-Firmware-Updates (Bestandsinstallationen) ───────
# Muss dem Container-User (uid 1000) gehören, BEVOR Compose ihn root-owned
# auto-anlegt — sonst kann screen_host die done/failed-Unterordner nicht anlegen.
UP_PROFILES="$(grep -E '^COMPOSE_PROFILES=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
if [[ "$UP_PROFILES" == *esp32* ]]; then
  UP_PICKUP="$(grep -E '^SCREEN_PICKUP_DIR=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  UP_PICKUP="${UP_PICKUP:-/opt/sermony-recorder/screen-pickup}"
  if [[ ! -d "$UP_PICKUP" ]] || [[ "$(stat -c '%u' "$UP_PICKUP" 2>/dev/null)" != "1000" ]]; then
    if install -d -o 1000 -g 1000 "$UP_PICKUP" 2>/dev/null; then
      c_green "Pickup-Ordner für Display-Updates: $UP_PICKUP"
    else
      c_yellow "Pickup-Ordner $UP_PICKUP konnte nicht angelegt/gechownt werden (sudo nötig?):"
      c_yellow "  sudo install -d -o 1000 -g 1000 $UP_PICKUP"
    fi
  fi
fi

# ── Images ziehen + Stack neu starten ─────────────────────────────────────────
cd "$DEPLOY_DIR"
c_green "Ziehe aktuelle Images..."
docker compose pull

# ── Ownership des Audio-Volumes (Bestandsinstallationen) ─────────────────────
# Docker uebernimmt die Ownership aus dem Image NUR beim Initialisieren eines
# LEEREN Volumes. Wessen audio-Volume noch unter dem alten, als root laufenden
# Image entstanden ist, hat es root-owned — der non-root-Container stirbt dann
# beim Import von log_manager (mkdir /mnt/audio/logs → EACCES), bevor irgendein
# Healthcheck greift. Einmalig geradeziehen; bei korrektem Owner ein No-op.
# Bewusst nur bei eindeutig gelesener Fremd-uid: lieber nichts tun als blind
# chownen, wenn die Abfrage schiefging.
AUDIO_OWNER="$(docker compose run --rm --no-deps --user 0 --entrypoint stat \
  media_capture_streaming -c '%u' /mnt/audio 2>/dev/null | tr -d '\r' | tail -n1 || true)"
if [[ "$AUDIO_OWNER" =~ ^[0-9]+$ ]] && [[ "$AUDIO_OWNER" != "1000" ]]; then
  c_yellow "Audio-Volume gehört uid $AUDIO_OWNER statt 1000 — ziehe Ownership gerade..."
  if docker compose run --rm --no-deps --user 0 --entrypoint chown \
       media_capture_streaming -R 1000:1000 /mnt/audio >/dev/null 2>&1; then
    c_green "Ownership des Audio-Volumes korrigiert."
  else
    c_red "Ownership konnte nicht korrigiert werden — der Recorder wird so nicht starten."
    c_yellow "  Manuell in $DEPLOY_DIR:"
    c_yellow "  docker compose run --rm --no-deps --user 0 --entrypoint chown media_capture_streaming -R 1000:1000 /mnt/audio"
  fi
fi

c_green "Starte Stack neu (nur geänderte Container werden ersetzt)..."
docker compose up -d
docker compose ps

if [[ $PRUNE -eq 1 ]]; then
  c_green "Räume alte Images auf..."
  docker image prune -f
fi

echo
c_green "Update abgeschlossen."
