"""nxport.json for the port pack (ios/Makefile `make pack`): nxport.in.json + the port version + per module what
modules.json (mkpack.py) and layout.json say. Format: see nx-packager's docs/PORT_PACKS.md.

usage: mknxport.py <port dir> <port version> <out nxport.json>"""
import json
import os
import sys

port, version, out = sys.argv[1:]
m = json.load(open(os.path.join(port, "nxport.in.json")))
layout = {e["name"]: e for e in json.load(open(os.path.join(port, "layout.json")))}
m["port_version"] = version
m["app"]["ipa_name"] = f"{m['port_name']}-{version}.ipa"
m["modules"] = []
for e in json.load(open(os.path.join(port, "modules.json"))):
    lay = layout[e["name"]]
    e.update(image_size=lay["image_size"], text_size=lay["text_size"],
             hooks=[{"offset": h["offset"], "size": 16} for h in lay["hooks"]])
    m["modules"].append(e)
json.dump(m, open(out, "w"), indent=1)
