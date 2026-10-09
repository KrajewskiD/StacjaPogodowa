#!/usr/bin/env python3
"""Odbiornik JSON/UDP ze StacjaPogodowa. Wymaga tylko Python 3.10+."""

import argparse
from datetime import datetime
import json
import math
import socket
import sys


FIELDS = (
    ("temperature_c", "Temperatura", "°C"),
    ("humidity_pct", "Wilgotność", "%"),
    ("wind_avg_ms", "Wiatr średni", "m/s"),
    ("wind_gust_ms", "Poryw", "m/s"),
    ("wind_direction_deg", "Kierunek", "°"),
    ("rain_total_mm", "Licznik deszczu", "mm"),
    ("uv_index", "UV", ""),
    ("light_klx", "Światło", "klx"),
    ("rssi_dbm", "RSSI radia", "dBm"),
)


def decode_packet(raw):
    data = json.loads(raw)
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise ValueError("nieobsługiwany format/schemat")
    if data.get("type") not in ("weather", "status"):
        raise ValueError("nieznany typ wiadomości")
    if data["type"] == "weather":
        sensor_id = data.get("sensor_id")
        if not isinstance(sensor_id, str) or len(sensor_id) != 8:
            raise ValueError("niepoprawny sensor_id")
        int(sensor_id, 16)
        for key, _, _ in FIELDS:
            if key in data:
                value = data[key]
                if type(value) not in (int, float) or not math.isfinite(value):
                    raise ValueError(f"niepoprawny pomiar: {key}")
    return data


def display(data, source):
    stamp = datetime.now().astimezone().isoformat(timespec="seconds")
    prefix = f"[{stamp}] {source}"
    if data["type"] == "status":
        radio = "OK" if data.get("radio_ok") is True else "BŁĄD"
        return (f"{prefix} STATUS radio={radio} "
                f"kod={data.get('radio_error', '?')} "
                f"ramki={data.get('decoded_packets', '?')} "
                f"wiek pomiaru={data.get('weather_age_s', 'brak')} s")
    values = [f"{label}: {data[key]:g} {unit}".rstrip()
              for key, label, unit in FIELDS if key in data]
    if type(data.get("battery_ok")) is bool:
        values.append("Bateria: " + ("OK" if data["battery_ok"] else "NISKA"))
    return (f"{prefix} CZUJNIK={data['sensor_id']} "
            f"dekoder={data.get('decoder', '?')} | " + " | ".join(values))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0", help="adres nasłuchu")
    parser.add_argument("--port", type=int, default=8680)
    parser.add_argument("--sensor-id", type=lambda s: f"{int(s, 16):08X}",
                        help="ID czujnika w zapisie szesnastkowym")
    parser.add_argument("--json", action="store_true", help="wypisuj JSON zamiast opisów")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port musi należeć do zakresu 1–65535")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind((args.bind, args.port))
            sock.settimeout(60)
            print(f"Nasłuch UDP {args.bind}:{args.port}; Ctrl+C kończy program.",
                  file=sys.stderr, flush=True)
            while True:
                try:
                    raw, (ip, _) = sock.recvfrom(8192)
                except socket.timeout:
                    print("Brak wiadomości przez 60 s. Sprawdź zasilanie ESP, Wi-Fi "
                          "i zaporę (UDP 8680).", file=sys.stderr, flush=True)
                    continue
                try:
                    data = decode_packet(raw)
                except (ValueError, UnicodeError, RecursionError) as exc:
                    print(f"Pominięto błędny pakiet z {ip}: {exc}", file=sys.stderr)
                    continue
                if (args.sensor_id and data["type"] == "weather"
                        and data["sensor_id"].upper() != args.sensor_id):
                    continue
                print(json.dumps(data, ensure_ascii=False) if args.json
                      else display(data, ip), flush=True)
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        print(f"Błąd UDP: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
