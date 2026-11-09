#!/usr/bin/env bash
#
# Sermony.Recorder — DNS über einen Zwischenspeicher auf dem Gerät (dnsmasq aus NetworkManager).
#
# Problem: Die Container lösen Namen über Dockers internen DNS (127.0.0.11) auf. Der leitet an
# die DNS-Server weiter, die in /etc/resolv.conf des Geräts standen, als der Container STARTETE —
# Docker liest die Datei danach nie wieder (moby: libnetwork/sandbox_dns_unix.go, setupDNS/
# rebuildDNS nur beim Start). Wechselt das Gerät das Netz (anderes WLAN, LAN statt WLAN, WLAN erst
# nach dem Booten verbunden), fragen die Container weiter den DNS-Server des alten Netzes und
# melden "Temporary failure in name resolution", bis sie neu starten.
#
# Lösung: NetworkManager startet dnsmasq auf 127.0.0.1 und trägt dort jeweils die DNS-Server des
# aktiven Netzes ein (dns=dnsmasq). In /etc/resolv.conf steht dann immer 127.0.0.1. Docker fragt
# Server auf der Loopback-Adresse des Geräts aus dessen Netz-Namespace an (HostLoopback,
# libnetwork/internal/resolvconf) — die Adresse der Container bleibt also gültig, während
# dahinter das Netz wechselt. Kein Neustart, keine Wartezeit.
#
# NICHT systemd-resolved: dessen 127.0.0.53 ersetzt Docker gezielt durch die festen Server aus
# /run/systemd/resolve/resolv.conf (resolvconf_path.go) — das Problem bliebe.
#
# Aufrufe (setup.sh/upgrade.sh rufen beide Schritte auf; einzeln mit sudo möglich):
#   dns-cache.sh host <deploy-dir>       → Gerät einrichten (vor `docker compose up`)
#   dns-cache.sh containers <deploy-dir> → Container, die noch mit dem alten Eintrag laufen,
#                                          einmalig neu starten und die Auflösung prüfen
#                                          (nach `docker compose up`)
# Beide Schritte sind idempotent und brechen nie das aufrufende Skript ab: was nicht passt,
# wird übersprungen bzw. zurückgenommen und erklärt.

if [ -z "${BASH_VERSION:-}" ]; then
  command -v bash >/dev/null 2>&1 || { echo "FEHLER: bash wird benötigt." >&2; exit 1; }
  exec bash "$0" "$@"
fi

set -uo pipefail

NM_CONF="/etc/NetworkManager/conf.d/90-sermony-dns.conf"
LOOPBACK_NS="127.0.0.1"

c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else return 1
  fi
}

host_uses_loopback() { grep -qE "^nameserver[[:space:]]+${LOOPBACK_NS//./\\.}([[:space:]]|$)" /etc/resolv.conf 2>/dev/null; }

# Wartet bis zu $2 Sekunden, bis /etc/resolv.conf auf 127.0.0.1 zeigt ($1=on) bzw. nicht mehr ($1=off).
wait_for_loopback() {
  local want="$1" i
  for ((i = 0; i < $2; i++)); do
    if host_uses_loopback; then [[ "$want" == on ]] && return 0
    else [[ "$want" == off ]] && return 0
    fi
    sleep 1
  done
  return 1
}

# Hostname aus SERMONY_HOST der .env (Schema, Port und Pfad entfernt).
sermony_hostname() {
  local env_file="$1" val
  val="$(grep -E '^SERMONY_HOST=' "$env_file" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r"'"'" || true)"
  val="${val#*://}"; val="${val%%/*}"; val="${val%%:*}"
  printf '%s' "${val:-app.sermony.de}"
}

# Nimmt die Einstellung zurück und wartet, bis NetworkManager wieder die Server des Netzes einträgt.
remove_nm_conf() {
  as_root rm -f "$NM_CONF" || return 0
  as_root nmcli general reload >/dev/null 2>&1 || true
  if ! wait_for_loopback off 10; then
    as_root systemctl restart NetworkManager >/dev/null 2>&1 || true
    wait_for_loopback off 20 || true
  fi
}

# ── Schritt 1: Gerät ──────────────────────────────────────────────────────────
setup_host() {
  local probe
  probe="$(sermony_hostname "$1/.env")"

  if ! command -v nmcli >/dev/null 2>&1 || ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
    c_yellow "DNS-Zwischenspeicher übersprungen: kein NetworkManager. Nach einem Netzwechsel"
    c_yellow "  brauchen die Container dann einen Neustart (docker compose restart)."
    return 0
  fi
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    c_yellow "DNS-Zwischenspeicher übersprungen: systemd-resolved verwaltet hier den DNS."
    return 0
  fi
  if systemctl is-active --quiet dnsmasq 2>/dev/null; then
    c_yellow "DNS-Zwischenspeicher übersprungen: ein eigener dnsmasq-Dienst belegt Port 53."
    return 0
  fi
  # Eine bewusst gesetzte andere DNS-Verwaltung nicht überschreiben (dns=default ist der Normalfall).
  local foreign
  foreign="$(grep -sHE '^[[:space:]]*dns[[:space:]]*=' /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/conf.d/*.conf \
             | grep -v "^${NM_CONF}:" | grep -vE '=[[:space:]]*(default|dnsmasq)[[:space:]]*$' || true)"
  if [[ -n "$foreign" ]]; then
    c_yellow "DNS-Zwischenspeicher übersprungen: NetworkManager hat eine eigene DNS-Einstellung:"
    c_yellow "  $foreign"
    return 0
  fi

  if ! command -v dnsmasq >/dev/null 2>&1 && [[ ! -x /usr/sbin/dnsmasq ]]; then
    c_green "Installiere dnsmasq-base (DNS-Zwischenspeicher für Netzwechsel)..."
    if ! { command -v apt-get >/dev/null 2>&1 \
           && { as_root apt-get install -y --no-install-recommends dnsmasq-base >/dev/null 2>&1 \
                || { as_root apt-get update >/dev/null 2>&1 \
                     && as_root apt-get install -y --no-install-recommends dnsmasq-base >/dev/null; }; }; }; then
      c_yellow "DNS-Zwischenspeicher übersprungen: dnsmasq-base ließ sich nicht installieren."
      c_yellow "  Von Hand: sudo apt-get install dnsmasq-base — danach dieses Skript erneut ausführen."
      return 0
    fi
  fi

  local want
  want="$(printf '%s\n' \
    '# Sermony.Recorder (scripts/dns-cache.sh): DNS über dnsmasq auf 127.0.0.1, damit die' \
    '# Container nach einem Netzwechsel ohne Neustart weiter Namen auflösen.' \
    '[main]' \
    'dns=dnsmasq')"
  if [[ -f "$NM_CONF" ]] && [[ "$(cat "$NM_CONF")" == "$want" ]] && host_uses_loopback; then
    c_green "DNS-Zwischenspeicher ist eingerichtet."
    return 0
  fi

  local resolved_before=0
  getent hosts "$probe" >/dev/null 2>&1 && resolved_before=1

  c_green "Richte DNS-Zwischenspeicher ein (Netzwechsel ohne Neustart der Container)..."
  if ! printf '%s\n' "$want" | as_root tee "$NM_CONF" >/dev/null; then
    c_yellow "DNS-Zwischenspeicher übersprungen: $NM_CONF nicht schreibbar (mit sudo ausführen)."
    return 0
  fi
  as_root chmod 644 "$NM_CONF"   # setup.sh läuft mit umask 077 (wegen der .env)
  as_root nmcli general reload >/dev/null 2>&1 || true
  if ! wait_for_loopback on 10; then
    # Ältere NetworkManager übernehmen den DNS-Wechsel erst beim Neustart. Bestehende
    # Verbindungen bleiben dabei stehen (NetworkManager baut beim Stoppen nichts ab).
    as_root systemctl restart NetworkManager >/dev/null 2>&1 || true
    wait_for_loopback on 20 || true
  fi

  if ! host_uses_loopback; then
    remove_nm_conf
    c_yellow "DNS-Zwischenspeicher zurückgenommen: NetworkManager hat /etc/resolv.conf nicht umgestellt."
    return 0
  fi
  if [[ $resolved_before -eq 1 ]] && ! getent hosts "$probe" >/dev/null 2>&1; then
    remove_nm_conf
    c_red "DNS-Zwischenspeicher zurückgenommen: $probe ließ sich darüber nicht auflösen."
    return 0
  fi
  c_green "DNS-Zwischenspeicher eingerichtet: /etc/resolv.conf zeigt auf $LOOPBACK_NS."
}

# ── Schritt 2: Container ──────────────────────────────────────────────────────
# Docker übernimmt den neuen Eintrag nur beim Start eines Containers. Wer vor der Umstellung
# gestartet ist, wird einmalig neu gestartet — danach nie wieder.
refresh_containers() {
  local deploy_dir="$1" probe ids id started conf_mtime started_epoch name restarted=0
  host_uses_loopback || return 0
  [[ -f "$NM_CONF" ]] || return 0
  cd "$deploy_dir" || return 0
  probe="$(sermony_hostname "$deploy_dir/.env")"

  conf_mtime="$(stat -c %Y "$NM_CONF")"
  ids="$(docker compose ps -q 2>/dev/null || true)"
  for id in $ids; do
    started="$(docker inspect -f '{{.State.StartedAt}}' "$id" 2>/dev/null || true)"
    started_epoch="$(date -d "$started" +%s 2>/dev/null || echo 0)"
    if (( started_epoch < conf_mtime )); then
      name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null)"
      c_yellow "Starte ${name#/} neu, damit er den DNS-Zwischenspeicher nutzt..."
      docker restart "$id" >/dev/null && restarted=1
    fi
  done

  # Prüfung im Container. Nur aussagekräftig, wenn das Gerät selbst den Namen auflösen kann
  # (ohne Netz würde sie sonst grundlos Alarm schlagen).
  getent hosts "$probe" >/dev/null 2>&1 || return 0
  [[ $restarted -eq 1 ]] && sleep 3
  # Exit 3 = Name nicht auflösbar. Alles andere (Container startet noch, exec scheitert) ist
  # KEIN Beleg gegen den Zwischenspeicher und darf ihn nicht zurücknehmen.
  local rc=0 try
  for try in 1 2 3; do
    docker compose exec -T server python -c \
      "import socket,sys
try: socket.getaddrinfo(sys.argv[1], 443)
except socket.gaierror: sys.exit(3)" "$probe" >/dev/null 2>&1
    rc=$?
    [[ $rc -eq 0 ]] && { c_green "DNS im Container ok: $probe wird aufgelöst."; return 0; }
    sleep 2
  done
  if [[ $rc -ne 3 ]]; then
    c_yellow "DNS im Container nicht prüfbar (server antwortet nicht) — später mit:"
    c_yellow "  sudo bash $0 containers $deploy_dir"
    return 0
  fi

  # Gerät löst auf, Container nicht → diese Docker-Version leitet nicht an 127.0.0.1 weiter.
  # Zurück zum vorherigen Zustand, damit der Recorder nicht schlechter dasteht als vorher.
  c_red "Der Container 'server' kann $probe über den DNS-Zwischenspeicher nicht auflösen."
  c_yellow "Nehme den Zwischenspeicher zurück und starte die Container neu..."
  remove_nm_conf
  docker compose restart >/dev/null 2>&1 || true
  c_yellow "  Ohne Zwischenspeicher brauchen die Container nach einem Netzwechsel einen Neustart"
  c_yellow "  (docker compose restart). Docker-Version: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unbekannt)"
}

[[ -n "${2:-}" && -d "${2:-}" ]] || { echo "Verwendung: $0 host|containers <deploy-dir>"; exit 2; }
case "${1:-}" in
  host)       setup_host "$2" ;;
  containers) refresh_containers "$2" ;;
  *)          echo "Verwendung: $0 host|containers <deploy-dir>"; exit 2 ;;
esac
exit 0
