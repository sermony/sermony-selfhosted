#!/usr/bin/env bash
#
# Sermony.Recorder — interaktives Setup für Production-Deployments (Raspberry Pi / Linux).
#
# Erzeugt die .env mit Secrets + Operator-Werten neben der docker-compose.yml
# (Release-Bundle: flach im Installationsordner; Git-Clone: unter deploy/).
#
# Idempotent + sicher: ein Re-Run BEWAHRT bestehende Werte (v.a. API_KEY und
# RECORDER_TOKEN). Vorhandene Werte werden gelesen und mit Enter behalten; nur
# fehlende Secrets werden frisch erzeugt. Wer alles neu will, löscht die .env.
#
# Muster analog Sermony.Web scripts/setup.sh.

# Unter sh/dash gestartet (z.B. `sh setup.sh`)? → mit bash re-execen; das Skript
# nutzt Bash-Features (pipefail, [[ ]], printf -v) und bricht unter dash sonst
# mit "set: Illegal option -o pipefail".
if [ -z "${BASH_VERSION:-}" ]; then
  command -v bash >/dev/null 2>&1 || { echo "FEHLER: bash wird benötigt." >&2; exit 1; }
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Zwei Layouts, automatisch erkannt:
#   • Git-Clone:       <repo>/scripts/setup.sh + <repo>/deploy/   (Maintainer)
#   • Release-Bundle:  alles flach neben setup.sh, z.B. /opt/sermony-recorder/  (Kunde)
if [[ -d "$SCRIPT_DIR/../deploy" ]]; then
  DEPLOY_DIR="$(cd "$SCRIPT_DIR/../deploy" && pwd)"
else
  DEPLOY_DIR="$SCRIPT_DIR"
fi
ENV_FILE="$DEPLOY_DIR/.env"

# Gehostete Sermony-Instanz — Default fuer alle, die nicht selbst hosten.
# Gegenstueck zu runtimeConfig.public.officialServerUrl in der Webapp.
OFFICIAL_SERMONY_URL="https://app.sermony.de"

c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Liest den Wert eines Keys aus einer .env (erste Fundstelle); Quotes + CRLF entfernt.
read_env_value() {
  local key="$1" file="$2" line val
  [[ -f "$file" ]] || return 0
  line="$(grep -E "^${key}=" "$file" | head -n1 || true)"
  [[ -n "$line" ]] || return 0
  val="${line#*=}"
  val="${val%$'\r'}"
  val="${val#\"}"; val="${val%\"}"
  val="${val#\'}"; val="${val%\'}"
  printf '%s' "$val"
}

# Prompt mit Default: prompt_value VAR "Frage" "default" [required]
prompt_value() {
  local __var="$1" question="$2" default="$3" required="${4:-}" input
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$question [$default]: " input
      input="${input:-$default}"
    else
      read -r -p "$question: " input
    fi
    # Auch reine Leerzeichen zaehlen als leer: sonst passiert ein " " die
    # Pflichtpruefung, wird beim Normalisieren zu "" und die .env ist still kaputt.
    if [[ -z "${input//[[:space:]]/}" && "$required" == "required" ]]; then
      c_yellow "  Pflichtfeld — bitte einen Wert eingeben."
      continue
    fi
    break
  done
  printf -v "$__var" '%s' "$input"
}

# Normalisiert eine getippte Adresse: Leerzeichen raus, fehlendes Schema auf
# https:// ergaenzen, trailing Slash abschneiden. Laien tippen "app.sermony.de"
# oder "https://app.sermony.de/" — beides landete bisher unveraendert in der .env
# und ergab beim Ableiten des Upload-Pfades eine kaputte URL.
normalize_url() {
  local u="${1// /}"
  [[ -n "$u" ]] || return 0
  [[ "$u" =~ ^https?:// ]] || u="https://$u"
  printf '%s' "${u%/}"
}

# Tippfehler in der Adresse sollen SOFORT auffallen, nicht erst wenn der Recorder
# stumm bleibt und niemand weiss warum. /api/health ist der Liveness-Endpunkt der
# Webapp: immer 200, kein Login noetig. Bewusst nur ein Hinweis und kein Abbruch —
# ein Geraet darf auch ohne Netz vorkonfiguriert werden.
check_sermony_reachable() {
  local base="$1" code
  command -v curl >/dev/null 2>&1 || return 0
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${base}/api/health" 2>/dev/null || true)"
  case "$code" in
    200)      c_green  "  Sermony ist unter dieser Adresse erreichbar." ;;
    000|"")   c_yellow "  Hinweis: keine Antwort von $base — Schreibweise prüfen, oder ist das Gerät noch ohne Netz?" ;;
    *)        c_yellow "  Hinweis: $base/api/health antwortet mit HTTP $code — ist das wirklich deine Sermony-Adresse?" ;;
  esac
}

command -v openssl >/dev/null 2>&1 || { c_red "openssl wird benötigt (API-Key-Generierung)."; exit 1; }
if ! command -v docker >/dev/null 2>&1; then
  c_red "Docker wird benötigt, ist aber nicht installiert."
  c_yellow "Debian/Raspberry Pi OS schnell:  curl -fsSL https://get.docker.com | sh"
  exit 1
fi

echo
c_green "── Sermony.Recorder Setup ─────────────────────────────────────────────"
if [[ -f "$ENV_FILE" ]]; then
  c_yellow ".env existiert — bestehende Werte werden vorgeschlagen/bewahrt."
fi
echo

# ── Bestehende Werte lesen ────────────────────────────────────────────────────
CUR_SERMONY_HOST="$(read_env_value SERMONY_HOST "$ENV_FILE")"
CUR_RECORDER_ID="$(read_env_value RECORDER_ID "$ENV_FILE")"
CUR_RECORDER_TOKEN="$(read_env_value RECORDER_TOKEN "$ENV_FILE")"
CUR_API_KEY="$(read_env_value API_KEY "$ENV_FILE")"
CUR_TZ="$(read_env_value TZ "$ENV_FILE")"
CUR_PROFILES="$(read_env_value COMPOSE_PROFILES "$ENV_FILE")"
CUR_AUDIO_CHANNELS="$(read_env_value AUDIO_CHANNELS "$ENV_FILE")"
CUR_IMAGE="$(read_env_value RECORDER_IMAGE "$ENV_FILE")"
CUR_SERMONY_UPLOAD="$(read_env_value SERMONY_UPLOAD "$ENV_FILE")"
# Legacy (vor ADR-029): eine gesetzte UPLOAD_URL bedeutete „Upload nach Sermony an".
# Wird nur noch gelesen, um beim ersten Re-Run nach dem Upgrade die richtige
# Vorauswahl zu treffen — geschrieben wird der Wert nicht mehr.
CUR_UPLOAD_URL="$(read_env_value UPLOAD_URL "$ENV_FILE")"
CUR_W_HOST="$(read_env_value W_HOST "$ENV_FILE")"
CUR_W_USERNAME="$(read_env_value W_USERNAME "$ENV_FILE")"
CUR_W_PASSWORD="$(read_env_value W_PASSWORD "$ENV_FILE")"
CUR_W_PATH="$(read_env_value W_PATH "$ENV_FILE")"
CUR_META_ORGANIZATION="$(read_env_value META_ORGANIZATION "$ENV_FILE")"
CUR_META_WEBSITE="$(read_env_value META_WEBSITE "$ENV_FILE")"
CUR_META_LANGUAGE="$(read_env_value META_LANGUAGE "$ENV_FILE")"
CUR_TITLE_PREFIX="$(read_env_value TITLE_PREFIX "$ENV_FILE")"
CUR_SCREEN_UPDATE_CHANNEL="$(read_env_value SCREEN_UPDATE_CHANNEL "$ENV_FILE")"
CUR_SCREEN_UPDATE_URL="$(read_env_value SCREEN_UPDATE_URL "$ENV_FILE")"
CUR_SCREEN_PICKUP_DIR="$(read_env_value SCREEN_PICKUP_DIR "$ENV_FILE")"

# ── Sermony-Anbindung ─────────────────────────────────────────────────────────
c_green "1/5 · Verbindung zu Sermony"
echo "Der Recorder meldet sich bei deiner Sermony-Instanz an und lädt die fertigen"
echo "Aufnahmen dorthin hoch. ID und Token bekommst du in der Webapp unter"
echo "Einstellungen → Recorder → Token. Der Token wird dort nur EINMAL angezeigt."
echo
echo "Adresse deiner Instanz: Wenn du Sermony selbst betreibst, trage deine eigene"
echo "Domain ein. Nutzt du das gehostete Sermony, drücke einfach Enter."
echo "Die Schreibweise ist egal — meine-gemeinde.de, https://meine-gemeinde.de oder"
echo "mit Schrägstrich am Ende ergeben alle dasselbe."
prompt_value SERMONY_HOST "Sermony-Adresse" "${CUR_SERMONY_HOST:-$OFFICIAL_SERMONY_URL}" required
SERMONY_HOST="$(normalize_url "$SERMONY_HOST")"
c_green "  → $SERMONY_HOST"
check_sermony_reachable "$SERMONY_HOST"
prompt_value RECORDER_ID "Recorder-ID (aus der Webapp)" "$CUR_RECORDER_ID" required
prompt_value RECORDER_TOKEN "Recorder-Token (aus der Webapp)" "$CUR_RECORDER_TOKEN" required
echo

# ── Allgemein ─────────────────────────────────────────────────────────────────
c_green "2/5 · Aufnahme-Grundeinstellungen"
echo "Die Zeitzone steuert, wann geplante Aufnahmen starten — steht hier die"
echo "falsche Zone, nimmt das Gerät zur falschen Uhrzeit auf."
prompt_value TZ "Zeitzone" "${CUR_TZ:-Europe/Berlin}"
echo
echo "Mono genügt für Predigten und halbiert die Dateigröße. Stereo nur, wenn ihr"
echo "bewusst zweikanalig abnehmt (z.B. Musik über ein Mischpult)."
prompt_value AUDIO_CHANNELS "Audio-Kanäle (1 = Mono, 2 = Stereo)" "${CUR_AUDIO_CHANNELS:-1}"
echo

# ── ESP32-Display ─────────────────────────────────────────────────────────────
c_green "3/5 · Status-Display (optional)"
echo "Gemeint ist das kleine per USB angeschlossene Display, das den Aufnahme-"
echo "Status anzeigt und Start/Stopp erlaubt. Ohne so ein Gerät: n."
DEFAULT_ESP32="n"; [[ "$CUR_PROFILES" == *esp32* ]] && DEFAULT_ESP32="j"
read -r -p "Display angeschlossen? (j/n) [$DEFAULT_ESP32]: " ESP32_ANSWER
ESP32_ANSWER="${ESP32_ANSWER:-$DEFAULT_ESP32}"
COMPOSE_PROFILES=""
[[ "$ESP32_ANSWER" =~ ^[jJyY] ]] && COMPOSE_PROFILES="esp32"
echo

# ── Upload-Ziel ───────────────────────────────────────────────────────────────
# Seit ADR-029 (resumierbarer Upload) gibt es KEINE UPLOAD_URL mehr: der Recorder
# fragt die Sermony-Instanz nach einer Upload-Sitzung und bekommt das Ziel samt
# kurzlebigem Token zugewiesen. SERMONY_HOST ist damit die einzige Angabe.
#
# Die frühere Option „eigener HTTP-Endpoint" ist deshalb ENTFALLEN — das Protokoll
# (Sitzung anlegen, tus, Registrierung abwarten) ist Sermony-spezifisch, eine
# beliebige Gegenstelle kann es nicht bedienen. Wer nur Dateien ablegen will, nimmt
# WebDAV. Bestehende .env-Dateien mit UPLOAD_URL werden beim Re-Run bereinigt.

# Default: was bisher konfiguriert war. Bei einer bestehenden .env ganz ohne
# Upload-Ziel bleibt es bei "keins" (sonst würde ein Enter-Durchklicken beim
# Re-Run stillschweigend Uploads einschalten); Neuinstallationen starten auf
# Sermony, das ist der Normalfall.
if [[ "$CUR_SERMONY_UPLOAD" == "0" ]];                        then DEFAULT_UPLOAD="3"
elif [[ -n "$CUR_SERMONY_UPLOAD" || -n "$CUR_UPLOAD_URL" ]];  then DEFAULT_UPLOAD="1"
elif [[ -n "$CUR_W_HOST" ]];                                  then DEFAULT_UPLOAD="2"
elif [[ -f "$ENV_FILE" ]];                                    then DEFAULT_UPLOAD="3"
else                                                               DEFAULT_UPLOAD="1"
fi

c_green "4/5 · Wohin sollen fertige Aufnahmen?"
echo "  1) Sermony — landen direkt in deiner Instanz und sind dort sofort"
echo "     in der Mediathek sichtbar (empfohlen)"
echo "  2) WebDAV — Nextcloud, ownCloud o.ä."
echo "  3) keins — Aufnahmen bleiben nur auf dem Gerät"
read -r -p "Auswahl [$DEFAULT_UPLOAD]: " UPLOAD_CHOICE
UPLOAD_CHOICE="${UPLOAD_CHOICE:-$DEFAULT_UPLOAD}"
SERMONY_UPLOAD_ENABLED="0"; W_HOST=""; W_USERNAME=""; W_PASSWORD=""; W_PATH="/"
case "$UPLOAD_CHOICE" in
  1)
    SERMONY_UPLOAD_ENABLED="1"
    c_green "  → $SERMONY_HOST (Ziel und Token weist Sermony pro Aufnahme zu)"
    ;;
  2)
    prompt_value W_HOST "WebDAV-Host (https://…)" "$CUR_W_HOST" required
    W_HOST="$(normalize_url "$W_HOST")"
    prompt_value W_USERNAME "WebDAV-Benutzer" "$CUR_W_USERNAME" required
    prompt_value W_PASSWORD "WebDAV-Passwort" "$CUR_W_PASSWORD" required
    prompt_value W_PATH "WebDAV-Zielpfad" "${CUR_W_PATH:-/}"
    ;;
esac
echo

# ── Metadaten (optional) ──────────────────────────────────────────────────────
c_green "5/5 · Angaben in der Audiodatei (optional)"
echo "Diese Werte schreibt der Recorder als ID3-Tags in jede MP3 — sie erscheinen"
echo "später im Player. Beides kann leer bleiben."
prompt_value META_ORGANIZATION "Gemeinde-/Organisationsname" "$CUR_META_ORGANIZATION"
prompt_value META_WEBSITE "Webseite" "$CUR_META_WEBSITE"
echo

# ── Secrets generieren (nur fehlende) ─────────────────────────────────────────
API_KEY="$CUR_API_KEY"
if [[ -z "$API_KEY" ]]; then
  API_KEY="$(openssl rand -hex 32)"
  c_green "API_KEY neu generiert."
else
  c_yellow "Bestehender API_KEY wird bewahrt."
fi

# ── .env schreiben ────────────────────────────────────────────────────────────
mkdir -p "$DEPLOY_DIR"
umask 077
cat > "$ENV_FILE" <<EOF
# Sermony.Recorder — generiert von setup.sh am $(date -Iseconds)
# Re-Run von setup.sh bewahrt Werte; upgrade.sh trägt neue Keys nach.

# Sermony-Anbindung
SERMONY_HOST=$SERMONY_HOST
RECORDER_ID=$RECORDER_ID
RECORDER_TOKEN=$RECORDER_TOKEN

# Sicherheit
API_KEY=$API_KEY

# Allgemein
TZ=$TZ
DEBUG=false
AUDIO_CHANNELS=$AUDIO_CHANNELS
RECORDER_IMAGE=${CUR_IMAGE:-ghcr.io/sermony/recorder:stable}

# Optionale Bausteine
COMPOSE_PROFILES=$COMPOSE_PROFILES

# Display-Firmware-Updates (nur mit esp32-Profil relevant)
SCREEN_UPDATE_CHANNEL=${CUR_SCREEN_UPDATE_CHANNEL:-stable}
SCREEN_UPDATE_URL=${CUR_SCREEN_UPDATE_URL:-}
SCREEN_PICKUP_DIR=${CUR_SCREEN_PICKUP_DIR:-/opt/sermony-recorder/screen-pickup}

# Upload-Ziel. Bei "Sermony" steht hier NICHTS: seit ADR-029 weist die Instanz das
# Upload-Ziel pro Aufnahme zu, SERMONY_HOST oben genügt. Nicht von Hand pflegen:
# setup.sh erneut ausführen.
SERMONY_UPLOAD=$SERMONY_UPLOAD_ENABLED
W_HOST=$W_HOST
W_USERNAME=$W_USERNAME
W_PASSWORD=$W_PASSWORD
W_PATH=$W_PATH

# ID3-Metadaten
META_ORGANIZATION=$META_ORGANIZATION
META_LANGUAGE=${CUR_META_LANGUAGE:-German}
META_WEBSITE=$META_WEBSITE
META_ARTIST=
META_ALBUM=
META_COMPOSER=
TITLE_PREFIX=${CUR_TITLE_PREFIX:-}
EOF
chmod 600 "$ENV_FILE"
c_green "$ENV_FILE geschrieben (chmod 600)."
echo

# ── Pickup-Ordner für Display-Firmware-Updates ────────────────────────────────
# Muss VOR dem Compose-Start existieren und dem Container-User (uid 1000)
# gehören — sonst legt Docker ihn root-owned an und screen_host kann die
# done/failed-Unterordner nicht anlegen.
if [[ "$COMPOSE_PROFILES" == *esp32* ]]; then
  PICKUP_DIR="${CUR_SCREEN_PICKUP_DIR:-/opt/sermony-recorder/screen-pickup}"
  if install -d -o 1000 -g 1000 "$PICKUP_DIR" 2>/dev/null; then
    c_green "Pickup-Ordner für Display-Updates: $PICKUP_DIR"
  else
    c_yellow "Pickup-Ordner $PICKUP_DIR konnte nicht angelegt werden (sudo nötig?):"
    c_yellow "  sudo install -d -o 1000 -g 1000 $PICKUP_DIR"
  fi
  echo
fi

# ── Start anbieten ────────────────────────────────────────────────────────────
read -r -p "Stack jetzt starten? (j/n) [j]: " START_ANSWER
START_ANSWER="${START_ANSWER:-j}"
if [[ "$START_ANSWER" =~ ^[jJyY] ]]; then
  cd "$DEPLOY_DIR"
  # Der Roh-Fehler von Docker ("Head https://…/manifests/stable: unauthorized")
  # sagt einem Nicht-Techniker nichts. Die .env ist zu diesem Zeitpunkt bereits
  # geschrieben — ein spaeterer Start holt den Pull nach, es geht nichts verloren.
  if ! docker compose pull; then
    echo
    c_red "Das Container-Image konnte nicht geladen werden."
    c_yellow "Eingestellt ist: $(read_env_value RECORDER_IMAGE "$ENV_FILE")"
    c_yellow "Meist heisst das: dieses Image ist (noch) nicht oeffentlich freigegeben"
    c_yellow "oder der Name stimmt nicht. Deine Angaben sind in $ENV_FILE gespeichert."
    c_yellow "Nach dem Klaeren genuegt:  cd $DEPLOY_DIR && docker compose up -d"
    exit 1
  fi
  docker compose up -d
  echo
  c_green "Gestartet. Status:  cd $DEPLOY_DIR && docker compose ps"
  c_green "Bedien-UI:          http://<host>:5000"
else
  c_yellow "Später starten mit:  cd $DEPLOY_DIR && docker compose up -d"
fi
