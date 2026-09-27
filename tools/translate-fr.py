#!/usr/bin/env python3
"""Fill the French column of the string catalogs. Run after `xcstringstool sync`; fails on any key left untranslated."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FR = {
    "%": "%",
    "%@ GB free": "%@ Go libres",
    "%@ of %@ GB": "%@ sur %@ Go",
    "About": "À propos",
    "Apps": "Apps",
    "Apps:": "Apps :",
    "Bar": "Barre",
    "Bluetooth": "Bluetooth",
    "Bluetooth Devices": "Appareils Bluetooth",
    "Bluetooth Devices Battery:": "Batterie des appareils Bluetooth :",
    "CPU": "CPU",
    "CPU Usage": "Utilisation du CPU",
    "CPU load and its recent history.": "Charge du CPU et son historique récent.",
    "Case": "Boîtier",
    "Compressed": "Compressée",
    "Compressed:": "Compressée :",
    "Copied": "Copié",
    "Copy": "Copier",
    "Details:": "Détails :",
    "Download": "Réception",
    "Download and upload speeds.": "Débits de réception et d'envoi.",
    "Download:": "Réception :",
    "Flash red on significant changes": "Clignoter en rouge lors d'un changement important",
    "Free": "Libre",
    "Free:": "Libre :",
    "GB": "Go",
    "GB/s": "Go/s",
    "GPU": "GPU",
    "GPU Usage": "Utilisation du GPU",
    "General": "Général",
    "IP Address": "Adresse IP",
    "IP Address:": "Adresse IP :",
    "Idle": "Inactif",
    "Idle:": "Inactif :",
    "If a device is missing, disconnect it and connect it again while the list refreshes.":
        "Si un appareil manque, déconnectez-le puis reconnectez-le pendant que la liste se met à jour.",
    "KB/s": "Ko/s",
    "Launch at login": "Ouvrir à la connexion",
    "Left": "Gauche",
    "MB/s": "Mo/s",
    "Made by Simplibot.": "Conçu par Simplibot.",
    "Measuring…": "Mesure en cours…",
    "Memory in use and how it splits.": "Mémoire utilisée et sa répartition.",
    "Metric:": "Mesure :",
    "Network": "Réseau",
    "Network Usage": "Utilisation du réseau",
    "Open Settings at launch": "Ouvrir les réglages au lancement",
    "Open SimplyBar to start measuring.": "Ouvrez SimplyBar pour lancer les mesures.",
    "Pressure": "Pression",
    "Pressure:": "Pression :",
    "Quit": "Quitter",
    "RAM": "RAM",
    "RAM Usage": "Utilisation de la RAM",
    "Requires approval in System Settings > General > Login Items.":
        "À autoriser dans Réglages Système > Général > Ouverture.",
    "Right": "Droite",
    "SSD": "SSD",
    "SSD Usage": "Utilisation du SSD",
    "Settings": "Réglages",
    "Show icon": "Afficher l'icône",
    "Show in menu bar": "Afficher dans la barre des menus",
    "Show label": "Afficher le libellé",
    "SimplyBar Settings": "Réglages de SimplyBar",
    "SimplyBar collects no data. Every measurement stays on this Mac.":
        "SimplyBar ne collecte aucune donnée. Chaque mesure reste sur ce Mac.",
    "Space used on the startup disk.": "Espace occupé sur le disque de démarrage.",
    "Style:": "Style :",
    "System": "Système",
    "System:": "Système :",
    "Total": "Total",
    "Total Usage": "Utilisation totale",
    "Total Usage:": "Utilisation totale :",
    "Total:": "Total :",
    "Unavailable": "Indisponible",
    "Update interval (seconds):": "Intervalle de mise à jour (secondes) :",
    "Upload": "Envoi",
    "Upload + Download": "Envoi + réception",
    "Upload:": "Envoi :",
    "Usage History": "Historique d'utilisation",
    "Usage History:": "Historique d'utilisation :",
    "Usage Per Core": "Utilisation par cœur",
    "Usage Per Core:": "Utilisation par cœur :",
    "Used": "Utilisé",
    "Used:": "Utilisé :",
    "User": "Utilisateur",
    "User + System": "Utilisateur + système",
    "User:": "Utilisateur :",
    "Wired": "Résidente",
    "Wired:": "Résidente :",
    "No Bluetooth device connected.": "Aucun appareil Bluetooth connecté.",
    "Battery not reported": "Batterie non communiquée",
    "Open Login Items Settings": "Ouvrir les réglages d'ouverture",
    "Updated %@": "Mis à jour à %@",
    "Version %@": "Version %@",
    "Enjoying SimplyBar?": "Vous aimez SimplyBar ?",
    "Rate it on the Mac App Store": "Laisser un avis sur le Mac App Store",
    "Available once SimplyBar is on the Mac App Store.": "Disponible dès que SimplyBar sera sur le Mac App Store.",
    "Legal": "Informations légales",
    "Privacy Policy": "Politique de confidentialité",
    "Have a question?": "Une question ?",
    "Email us at:": "Écrivez-nous à :",
    "Support": "Assistance",
    "Website": "Site web",
    "Storage": "Stockage",
    "Used, free and purgeable space on every disk.": "Espace utilisé, libre et purgeable sur chaque disque.",
    "Disk": "Disque",
    "Disks appear within 5 minutes.": "Les disques s'affichent d'ici 5 minutes.",
    "Including %@ GB purgeable": "Dont %@ Go purgeables",
    # InfoPlist.xcstrings
    "CFBundleDisplayName": "SimplyBar",
}

# Keys of InfoPlist.xcstrings are Info.plist keys; English values come from the build settings.
EN_INFOPLIST = {
    "CFBundleDisplayName": "SimplyBar",
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def fill(path, infoplist=False):
    catalog = json.loads(path.read_text(encoding="utf-8"))
    missing = []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        if key not in FR:
            missing.append(key)
            continue
        locs = entry.setdefault("localizations", {})
        if infoplist:
            locs["en"] = unit(EN_INFOPLIST[key])
        locs["fr"] = unit(FR[key])
        entry.pop("extractionState", None) if entry.get("extractionState") == "stale" else None
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return missing


missing = fill(ROOT / "Shared/Localizable.xcstrings")
missing += fill(ROOT / "SimplyBar/InfoPlist.xcstrings", infoplist=True)
for key in missing:
    print(f"missing fr: {key!r}")
sys.exit(1 if missing else 0)
