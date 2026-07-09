#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_scan_for_llms.sh  –  LLM-Host-Scanner
======================================
Scannt eine Ziel-IP nach LLM-Servern (vLLM, Ollama, LM Studio,
text-generation-webui, llama.cpp, LocalAI ...) und gibt volle Details
zu Host-Typ, Webserver, Modellen und Versionen aus.

Bedienung:
  - Beim Start wird eine IP abgefragt. Die zuletzt verwendete IP wird
    gemerkt und als Vorschlag angeboten (Enter = Vorschlag uebernehmen).
  - Menue:
      1) Standard-Port-Scan   (bekannte LLM-/Dienst-Ports)
      2) Voller Port-Scan      (Bereich frei waehlbar) + LLM-Probe bei Treffern
      3) IP wechseln
      0) Beenden

Nur Python-Standardbibliothek – keine externen Abhaengigkeiten.
Aufruf:  python3 _scan_for_llms.sh   (oder ausfuehrbar: ./_scan_for_llms.sh)
"""

import socket
import ssl
import json
import os
import sys
import ipaddress
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib import request, error

__version__ = "0.9.1"

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

LAST_IP_FILE = os.path.join(os.path.expanduser("~"), ".scan_for_llms_last_ip")

# Standard-Ports gaengiger LLM-Server und benachbarter Dienste
STANDARD_PORTS = [
    22,     # SSH (Banner)
    3128,   # Squid-Proxy
    1234,   # LM Studio
    1235,   # LM Studio (alt)
    3000,   # diverse UIs / TGI
    4000,   # diverse
    5000,   # text-generation-webui API
    5001,   # KoboldCpp
    7860,   # Gradio / text-generation-webui UI
    8000,   # vLLM / OpenAI-kompatibel (Default)
    8001,   # vLLM (alt)
    8080,   # llama.cpp / LocalAI / OpenAI-kompatibel
    8081,   # diverse
    8443,   # HTTPS-API
    8888,   # diverse
    9000,   # diverse
    9081,   # benutzerdef.
    9082,   # benutzerdef. (vLLM gesehen)
    11434,  # Ollama (Default)
    11435,  # Ollama (alt)
]

CONNECT_TIMEOUT = 2.0   # TCP-Connect-Timeout pro Port
HTTP_TIMEOUT = 6.0      # HTTP-Request-Timeout
MAX_WORKERS = 200       # parallele Verbindungen beim Scan

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


# ---------------------------------------------------------------------------
# Hilfsfunktionen: zuletzt genutzte IP merken
# ---------------------------------------------------------------------------

def load_last_ip():
    try:
        with open(LAST_IP_FILE, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def save_last_ip(ip):
    try:
        with open(LAST_IP_FILE, "w", encoding="utf-8") as fh:
            fh.write(ip.strip())
    except OSError:
        pass


def valid_ip(text):
    try:
        ipaddress.ip_address(text.strip())
        return True
    except ValueError:
        return False


# ---------------------------------------------------------------------------
# Low-Level-Netzwerk
# ---------------------------------------------------------------------------

def port_open(ip, port, timeout=CONNECT_TIMEOUT):
    """Reines TCP-Connect: True wenn Port offen."""
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except (OSError, socket.timeout):
        return False


def grab_banner(ip, port, timeout=CONNECT_TIMEOUT):
    """Liest einen Klartext-Banner (z.B. SSH), ohne selbst Daten zu senden."""
    try:
        with socket.create_connection((ip, port), timeout=timeout) as s:
            s.settimeout(timeout)
            data = s.recv(256)
            return data.decode("latin-1", "replace").strip()
    except (OSError, socket.timeout):
        return ""


def http_request(scheme, ip, port, path, timeout=HTTP_TIMEOUT):
    """
    HTTP(S)-GET. Gibt (code, headers_dict, body_text) zurueck.
    Behandelt auch Fehlerstatus (400/404/407) als verwertbares Ergebnis.
    """
    url = "%s://%s:%d%s" % (scheme, ip, port, path)
    req = request.Request(url, headers={"User-Agent": "scan_for_llms/1.0"})
    try:
        if scheme == "https":
            resp = request.urlopen(req, timeout=timeout, context=SSL_CTX)
        else:
            resp = request.urlopen(req, timeout=timeout)
        body = resp.read(65536).decode("utf-8", "replace")
        return resp.getcode(), dict(resp.headers), body
    except error.HTTPError as e:
        body = ""
        try:
            body = e.read(65536).decode("utf-8", "replace")
        except Exception:
            pass
        return e.code, dict(e.headers), body
    except Exception:
        return None, {}, ""


def http_json(scheme, ip, port, path, timeout=HTTP_TIMEOUT):
    code, headers, body = http_request(scheme, ip, port, path, timeout)
    if code == 200 and body:
        try:
            return json.loads(body)
        except ValueError:
            return None
    return None


# ---------------------------------------------------------------------------
# Dienst-Identifikation
# ---------------------------------------------------------------------------

def identify_service(ip, port):
    """
    Untersucht einen offenen Port und liefert ein Dict mit:
      port, type, server, version, models[], extra, banner, scheme
    """
    result = {
        "port": port,
        "type": "unbekannt",
        "server": "",
        "version": "",
        "models": [],
        "extra": "",
        "scheme": "http",
        "api_base": "",
        "endpoints": [],
    }

    # 1) Klartext-Banner (SSH etc.)
    banner = grab_banner(ip, port)
    if banner and banner.startswith("SSH-"):
        result["type"] = "SSH"
        result["server"] = banner
        return result

    # 2) HTTP/HTTPS testen
    scheme_found = None
    server_hdr = ""
    for scheme in ("http", "https"):
        code, headers, _ = http_request(scheme, ip, port, "/")
        if code is not None:
            scheme_found = scheme
            server_hdr = headers.get("Server", "") or headers.get("server", "")
            result["scheme"] = scheme
            result["server"] = server_hdr
            break

    if scheme_found is None:
        # weder Klartext-Banner noch HTTP -> nur "offen"
        result["type"] = "offen (unbekannt)"
        if banner:
            result["extra"] = "Banner: " + banner[:60]
        return result

    scheme = scheme_found

    base = "%s://%s:%d" % (scheme, ip, port)

    # 3) Squid-Proxy?
    if "squid" in server_hdr.lower():
        result["type"] = "HTTP-Proxy (Squid)"
        result["api_base"] = base
        result["extra"] = "Server: " + server_hdr
        return result

    # 4) OpenAI-kompatibel (vLLM / llama.cpp / LocalAI / LM Studio ...)
    models_doc = http_json(scheme, ip, port, "/v1/models")
    if models_doc and isinstance(models_doc.get("data"), list):
        owners = set()
        for m in models_doc["data"]:
            entry = {
                "id": m.get("id", "?"),
                "owned_by": m.get("owned_by", ""),
                "max_model_len": m.get("max_model_len", ""),
                "created": m.get("created", ""),
                "root": m.get("root", ""),
            }
            result["models"].append(entry)
            if entry["owned_by"]:
                owners.add(entry["owned_by"])

        # Typ anhand owned_by / Server-Header / Version-Endpunkt bestimmen
        ver = http_json(scheme, ip, port, "/version")
        if isinstance(ver, dict) and ver.get("version"):
            result["version"] = ver["version"]

        if "vllm" in owners or "vllm" in server_hdr.lower():
            result["type"] = "vLLM (OpenAI-API)"
        elif "uvicorn" in server_hdr.lower():
            result["type"] = "OpenAI-kompatibel (uvicorn/FastAPI)"
        else:
            result["type"] = "OpenAI-kompatibel"
        result["api_base"] = base + "/v1"
        result["endpoints"] = [
            base + "/v1/models",
            base + "/v1/chat/completions",
            base + "/v1/completions",
        ]
        result["extra"] = "Server: " + (server_hdr or "?")
        return result

    # 5) Ollama?
    ova_ver = http_json(scheme, ip, port, "/api/version")
    ova_tags = http_json(scheme, ip, port, "/api/tags")
    if ova_ver or ova_tags:
        result["type"] = "Ollama"
        if isinstance(ova_ver, dict):
            result["version"] = ova_ver.get("version", "")
        if isinstance(ova_tags, dict):
            for m in ova_tags.get("models", []):
                det = m.get("details", {}) or {}
                result["models"].append({
                    "id": m.get("name", m.get("model", "?")),
                    "owned_by": det.get("family", ""),
                    "max_model_len": det.get("parameter_size", ""),
                    "created": m.get("modified_at", ""),
                    "root": det.get("quantization_level", ""),
                })
        result["api_base"] = base + "/api"
        result["endpoints"] = [
            base + "/api/tags",
            base + "/api/chat",
            base + "/api/generate",
        ]
        result["extra"] = "Server: " + (server_hdr or "ollama")
        return result

    # 6) Generischer Webserver / unklar
    result["type"] = "HTTP-Dienst"
    result["extra"] = "Server: " + (server_hdr or "?") + " (keine LLM-API erkannt)"
    return result


# ---------------------------------------------------------------------------
# Scans
# ---------------------------------------------------------------------------

def scan_ports(ip, ports):
    """Parallel: liefert sortierte Liste offener Ports."""
    open_ports = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futs = {pool.submit(port_open, ip, p): p for p in ports}
        for fut in as_completed(futs):
            p = futs[fut]
            try:
                if fut.result():
                    open_ports.append(p)
            except Exception:
                pass
    return sorted(open_ports)


# ---------------------------------------------------------------------------
# Ausgabe
# ---------------------------------------------------------------------------

def print_service(info):
    line = "  [Port %-5d] %s" % (info["port"], info["type"])
    print(line)
    if info.get("server"):
        print("      Server/Banner : %s" % info["server"])
    if info.get("version"):
        print("      Version       : %s" % info["version"])
    if info.get("api_base"):
        print("      API-URL       : %s" % info["api_base"])
    if info.get("endpoints"):
        print("      Endpunkte     :")
        for ep in info["endpoints"]:
            print("                      %s" % ep)
    if info.get("extra"):
        print("      Info          : %s" % info["extra"])
    if info.get("models"):
        print("      Modelle (%d):" % len(info["models"]))
        for m in info["models"]:
            print("        - %s" % m["id"])
            details = []
            if m.get("owned_by"):
                details.append("owned_by/Familie=%s" % m["owned_by"])
            if m.get("max_model_len"):
                details.append("Kontext/Params=%s" % m["max_model_len"])
            if m.get("root"):
                details.append("root/Quant=%s" % m["root"])
            if details:
                print("            " + ", ".join(details))
    print()


def report(ip, open_ports, scan_label):
    print()
    print("=" * 64)
    print(" Ergebnis fuer %s  (%s)" % (ip, scan_label))
    print("=" * 64)
    if not open_ports:
        print(" Keine offenen Ports im untersuchten Bereich gefunden.")
        print()
        return

    print(" Offene Ports: %s" % ", ".join(str(p) for p in open_ports))
    print("-" * 64)

    llm_found = False
    for p in open_ports:
        info = identify_service(ip, p)
        if "vLLM" in info["type"] or "Ollama" in info["type"] or "OpenAI" in info["type"]:
            llm_found = True
        print_service(info)

    print("-" * 64)
    if llm_found:
        print(" >> LLM-Server gefunden (siehe oben).")
    else:
        print(" >> Kein direkt erreichbarer LLM-Server entdeckt.")
    print()


# ---------------------------------------------------------------------------
# Voller Port-Scan
# ---------------------------------------------------------------------------

def full_scan(ip):
    print()
    print(" Voller Port-Scan – Bereich angeben (Enter = 1-10000).")
    raw = input(" Bereich start-ende: ").strip()
    if not raw:
        start, end = 1, 10000
    else:
        try:
            parts = raw.replace(" ", "").split("-")
            start = int(parts[0])
            end = int(parts[1]) if len(parts) > 1 else int(parts[0])
        except (ValueError, IndexError):
            print(" Ungueltige Eingabe – verwende 1-10000.")
            start, end = 1, 10000
    start = max(1, start)
    end = min(65535, end)
    if end < start:
        start, end = end, start

    ports = list(range(start, end + 1))
    print(" Scanne %d Ports (%d-%d) ... das kann dauern." % (len(ports), start, end))
    open_ports = scan_ports(ip, ports)
    report(ip, open_ports, "Voller Scan %d-%d" % (start, end))


# ---------------------------------------------------------------------------
# IP-Abfrage
# ---------------------------------------------------------------------------

def ask_ip():
    last = load_last_ip()
    while True:
        if last:
            prompt = " Ziel-IP [%s]: " % last
        else:
            prompt = " Ziel-IP: "
        raw = input(prompt).strip()
        if not raw and last:
            raw = last
        if valid_ip(raw):
            save_last_ip(raw)
            return raw
        print(" Bitte eine gueltige IP-Adresse eingeben.")


# ---------------------------------------------------------------------------
# Hauptmenue
# ---------------------------------------------------------------------------

def menu():
    print()
    print("#" * 64)
    print("#  LLM-Host-Scanner  –  _scan_for_llms")
    print("#" * 64)

    ip = ask_ip()

    while True:
        print()
        print(" Aktuelle Ziel-IP: %s" % ip)
        print(" -------------------------------------------")
        print("  1) Standard-Port-Scan (bekannte LLM-Ports)")
        print("  2) Voller Port-Scan (Bereich) + LLM-Probe")
        print("  3) IP wechseln")
        print("  0) Beenden")
        choice = input(" Auswahl: ").strip()

        if choice == "1":
            print(" Scanne %d Standard-Ports ..." % len(STANDARD_PORTS))
            open_ports = scan_ports(ip, STANDARD_PORTS)
            report(ip, open_ports, "Standard-Ports")
        elif choice == "2":
            full_scan(ip)
        elif choice == "3":
            ip = ask_ip()
        elif choice == "0":
            print(" Beendet.")
            return
        else:
            print(" Ungueltige Auswahl.")


def main():
    try:
        menu()
    except (KeyboardInterrupt, EOFError):
        print("\n Abgebrochen.")
        sys.exit(0)


if __name__ == "__main__":
    main()
