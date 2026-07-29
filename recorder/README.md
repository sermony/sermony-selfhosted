# Sermony Recorder — Installation

Dieses Paket enthält alles, was auf dem Aufnahme-Gerät (z.B. Raspberry Pi) gebraucht
wird. Die eigentliche Software kommt als fertiges Container-Image — es muss nichts
gebaut werden.

## Voraussetzungen

- Docker mit Docker Compose v2 (`curl -fsSL https://get.docker.com | sh`)
- Zugangsdaten aus der Sermony-Webapp (Einstellungen → Recorder):
  Sermony-URL, Recorder-ID, Recorder-Token

## Installation

```bash
cd /opt/sermony-recorder     # Ordner, in den dieses Paket entpackt wurde
sudo ./setup.sh              # fragt die Werte ab, startet den Recorder
```

`setup.sh` kann jederzeit erneut ausgeführt werden — bestehende Werte bleiben erhalten.
Wo bereits etwas eingetragen ist, steht es als Vorschlag in eckigen Klammern; Enter
übernimmt ihn.

### Was abgefragt wird

1. **Verbindung zu Sermony** — Adresse deiner Instanz (selbst gehostet: eigene Domain,
   sonst Enter für das gehostete Sermony) sowie Recorder-ID und -Token aus der Webapp.
2. **Aufnahme** — Zeitzone (steuert geplante Aufnahmen) und Mono/Stereo.
3. **Status-Display** — nur falls das USB-Display angeschlossen ist.
4. **Upload-Ziel** — normalerweise „Sermony": die Aufnahmen landen direkt in deiner
   Instanz, die Adresse dafür ergibt sich automatisch aus Schritt 1. Alternativ ein
   eigener HTTP-Endpoint, WebDAV (Nextcloud & Co.) oder gar keiner.
5. **Angaben in der Audiodatei** — Gemeindename und Webseite für die MP3-Tags, optional.

## Update

```bash
cd /opt/sermony-recorder
sudo ./upgrade.sh            # holt das neueste Paket + Image und startet neu
```

## Status & Logs

```bash
cd /opt/sermony-recorder
docker compose ps
docker compose logs -f
```

Die Bedienoberfläche des Recorders läuft danach auf `http://<geräte-adresse>:5000`.
