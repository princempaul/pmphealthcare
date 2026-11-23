#!/usr/bin/env python3
"""Make sure Katrina PA has an internal TestFlight group that gets every build, with the
account's Admin / Account Holder users in it, so new builds show up in TestFlight on Paul's phone.

Runs in GitHub Actions with the App Store Connect API key from the repo secrets. Prints counts
and statuses only, never names or emails (the repo is public).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "ca.pmphealthcare.katrina"
GROUP_NAME = "Me"
ROLES = {"ACCOUNT_HOLDER", "ADMIN"}


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900,
                       "aud": "appstoreconnect-v1"},
                      os.environ["ASC_KEY_P8"], algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


TOKEN = token()


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + TOKEN,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            errs = json.loads(raw).get("errors", [])
            detail = "; ".join("%s: %s" % (x.get("title"), x.get("detail")) for x in errs)
        except ValueError:
            detail = raw[:300].decode(errors="replace")
        return e.code, {"error": detail}


def must(status, data, what):
    if status >= 300:
        print("::error::%s failed (%s): %s" % (what, status, data.get("error")))
        sys.exit(1)
    return data


def main():
    app = must(*call("GET", "/apps?filter[bundleId]=%s&limit=1" % BUNDLE_ID), "Finding the app")["data"]
    if not app:
        print("::error::No app with bundle ID %s in App Store Connect." % BUNDLE_ID)
        return 1
    app_id = app[0]["id"]
    print("App found.")

    groups = must(*call("GET", "/apps/%s/betaGroups?limit=50" % app_id), "Listing tester groups")["data"]
    group = next((g for g in groups if g["attributes"].get("isInternalGroup")
                  and g["attributes"].get("name") == GROUP_NAME), None)
    if group:
        print("Internal group '%s' already exists." % GROUP_NAME)
        if not group["attributes"].get("hasAccessToAllBuilds"):
            s, d = call("PATCH", "/betaGroups/" + group["id"], {"data": {
                "type": "betaGroups", "id": group["id"], "attributes": {"hasAccessToAllBuilds": True}}})
            print("Turned on 'all builds' for it." if s < 300 else "::warning::Couldn't turn on all builds: %s" % d.get("error"))
    else:
        group = must(*call("POST", "/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": GROUP_NAME, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}),
            "Creating the internal group")["data"]
        print("Created internal group '%s' with access to every build." % GROUP_NAME)
    gid = group["id"]

    users = must(*call("GET", "/users?limit=100"), "Listing App Store Connect users")["data"]
    picked = [u for u in users if ROLES & set(u["attributes"].get("roles") or [])]
    print("%d App Store Connect user(s) with Admin or Account Holder role." % len(picked))

    existing = must(*call("GET", "/betaGroups/%s/betaTesters?limit=200" % gid), "Listing group testers")["data"]
    have = {(t["attributes"].get("email") or "").lower() for t in existing}

    added = 0
    for u in picked:
        a = u["attributes"]
        email = (a.get("username") or a.get("email") or "").lower()
        if not email or email in have:
            continue
        s, d = call("POST", "/betaTesters", {"data": {
            "type": "betaTesters",
            "attributes": {"email": email, "firstName": a.get("firstName") or "", "lastName": a.get("lastName") or ""},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}}}})
        if s == 409:   # already a tester on this team: link the existing tester to the group
            s2, d2 = call("GET", "/betaTesters?filter[email]=%s&limit=1" % urllib.request.quote(email))
            tid = (d2.get("data") or [{}])[0].get("id")
            if tid:
                s, d = call("POST", "/betaGroups/%s/relationships/betaTesters" % gid,
                            {"data": [{"type": "betaTesters", "id": tid}]})
        if s < 300:
            added += 1
        else:
            print("::warning::Couldn't add one user (%s): %s" % (s, d.get("error")))
    print("Added %d tester(s); %d were already in the group." % (added, len(have)))

    builds = must(*call("GET", "/builds?filter[app]=%s&sort=-uploadedDate&limit=3" % app_id), "Listing builds")["data"]
    for b in builds:
        at = b["attributes"]
        print("Build %s: processing=%s, expired=%s" % (at.get("version"), at.get("processingState"), at.get("expired")))
    print("Done. Open TestFlight on the iPhone (same Apple ID) and Katrina PA should be there once processing is VALID.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
