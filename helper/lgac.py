#!/usr/bin/env python3
"""LG ThinQ AC helper. Usage: lgac.py status | refresh-devices | power ID on|off | temp ID +|-|<value> | mode ID MODE | fan ID SPEED | save ID on|off | swing ID on|off"""
import asyncio, json, os, sys, uuid, aiohttp
from thinqconnect import ThinQApi
from thinqconnect.thinq_api import ThinQAPIException
CFG = os.path.expanduser(os.environ.get("LG_AC_HOME", "~/.config/lg-ac"))
DEV = os.path.join(CFG, "devices.json"); LAST = os.path.join(CFG, "last_status.json")
def client_id():
    p = os.path.join(CFG, "client_id")
    if not os.path.exists(p):
        os.makedirs(CFG, exist_ok=True); open(p, "w").write(str(uuid.uuid4()))
    return open(p).read().strip()
async def devices(api, force=False):
    if not force and os.path.exists(DEV):
        return json.load(open(DEV))
    out = []
    for d in await api.async_get_device_list():
        if d["deviceInfo"]["deviceType"] != "DEVICE_AIR_CONDITIONER": continue
        pr = (await api.async_get_device_profile(d["deviceId"]))["property"]
        out.append({"id": d["deviceId"], "name": d["deviceInfo"].get("alias"),
            "modes": pr["airConJobMode"]["currentJobMode"]["value"]["w"],
            "fans": pr["airFlow"]["windStrength"]["value"]["w"]})
    json.dump(out, open(DEV, "w")); return out
async def run(argv):
    token = os.environ.get("LG_THINQ_PAT") or open(os.environ.get("LG_THINQ_TOKEN_FILE", os.path.join(CFG, "token"))).read().strip()
    async with aiohttp.ClientSession() as s:
        api = ThinQApi(session=s, access_token=token, country_code=os.environ.get("LG_THINQ_COUNTRY", "BR"), client_id=client_id())
        cmd = argv[0]
        if cmd in ("status", "refresh-devices"):
            out = []
            for d in await devices(api, cmd == "refresh-devices"):
                out.append(dict(d, status=await api.async_get_device_status(d["id"])))
            json.dump(out, open(LAST, "w")); print(json.dumps(out)); return
        dev = argv[1]; arg = argv[2]
        if cmd == "power":
            p = {"operation": {"airConOperationMode": "POWER_ON" if arg == "on" else "POWER_OFF"}}
        elif cmd == "temp":
            if arg in "+-":
                cur = (await api.async_get_device_status(dev))["temperature"]["targetTemperature"]
                v = cur + (1 if arg == "+" else -1)
            else: v = float(arg)
            v = max(16, min(30, v))
            p = {"temperature": {"targetTemperature": v, "unit": "C"}}
        elif cmd == "mode": p = {"airConJobMode": {"currentJobMode": arg}}
        elif cmd == "fan": p = {"airFlow": {"windStrength": arg}}
        elif cmd == "save": p = {"powerSave": {"powerSaveEnabled": arg == "on"}}
        elif cmd == "swing": p = {"windDirection": {"rotateUpDown": arg == "on"}}
        else: sys.exit(__doc__)
        await api.async_post_device_control(dev, p)
        print(json.dumps({"ok": True}))
try:
    asyncio.run(run(sys.argv[1:] or ["status"]))
except ThinQAPIException as e:
    msg = str(e)
    print(json.dumps({"error": "rate_limit" if ("1314" in msg or "Exceeded" in msg) else msg})); sys.exit(2)
except Exception as e:
    print(json.dumps({"error": f"{type(e).__name__}: {e}"})); sys.exit(2)
