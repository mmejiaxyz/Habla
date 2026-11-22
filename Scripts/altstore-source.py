#!/usr/bin/env python3
"""Writes the AltStore source for a release: altstore-source.py <build> <ipa> <out.json>."""
import datetime, json, os, sys

REPO = "mmejiaxyz/Habla"
build, ipa, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
version = f"1.{build}"
url = f"https://github.com/{REPO}/releases/download/build-{build}/Habla.ipa"
date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
size = os.path.getsize(ipa)
desc = "Listen to and read the books Habla Studio narrates on your Mac."
source = {
    "name": "Habla",
    "identifier": "com.habla.source",
    "sourceURL": f"https://github.com/{REPO}/releases/latest/download/altstore.json",
    "apps": [{
        "name": "Habla",
        "bundleIdentifier": "com.habla.app",
        "developerName": "Habla",
        "subtitle": "Your books, read aloud.",
        "localizedDescription": desc,
        "iconURL": f"https://raw.githubusercontent.com/{REPO}/main/Apps/Habla/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        "tintColor": "557795",
        "category": "entertainment",
        "screenshots": [],
        "versions": [{
            "version": version, "buildVersion": str(build), "date": date,
            "localizedDescription": f"Build {build}", "downloadURL": url, "size": size, "minOSVersion": "17.0",
        }],
        # Legacy (AltStore 1.x) fields.
        "version": version, "versionDate": date, "versionDescription": f"Build {build}", "downloadURL": url, "size": size,
        "appPermissions": {
            "entitlements": [],
            "privacy": {"NSLocalNetworkUsageDescription": "Habla finds Habla Studio on your Mac to download books and sync your place."},
        },
    }],
    "news": [],
}
with open(out, "w") as f:
    json.dump(source, f, indent=2)
