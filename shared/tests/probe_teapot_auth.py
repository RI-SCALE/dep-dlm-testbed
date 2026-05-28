# probe_teapot_auth.py — run with: python3 probe_teapot_auth.py
import requests
import base64
import json
import urllib3

urllib3.disable_warnings()

KC = "https://keycloak:8443/realms/rucio/protocol/openid-connect/token"


def get_token(scope):
    r = requests.post(
        KC,
        data={
            "grant_type": "password",
            "username": "randomaccount",
            "password": "secret",
            "scope": scope,
        },
        auth=("rucio", "rucio-secret"),
        verify=False,
        timeout=10,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def claims(tok):
    return json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "=="))


def propfind(url, tok):
    return requests.request(
        "PROPFIND",
        url,
        headers={"Authorization": f"Bearer {tok}", "Depth": "0"},
        verify=False,
        timeout=30,
    )


for scope in [
    "openid storage.read:/ storage.modify:/",  # no aud
    "openid storage.read:/ storage.modify:/ aud:teapot1",  # teapot1 aud
]:
    tok = get_token(scope)
    c = claims(tok)
    print(f"\nscope = {scope!r}")
    print(f"  aud   = {c.get('aud')!r}")
    print(f"  scope = {c.get('scope')!r}")
    r = propfind("https://teapot1:8081/data/", tok)
    print(f"  PROPFIND /data/ -> HTTP {r.status_code}")

# also: no token at all (tests anonymousReadEnabled)
r = requests.request(
    "PROPFIND",
    "https://teapot1:8081/data/",
    headers={"Depth": "0"},
    verify=False,
    timeout=30,
)
print(f"\nno token -> HTTP {r.status_code}")
