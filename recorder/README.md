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
