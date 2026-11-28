#!/usr/bin/env python3
"""Jane desk fence: the browser tool may only be sent to Jane's own sites.

Runs before every Chrome tool call (a PreToolUse hook). Exit 2 blocks the call and
shows the message to Claude. It checks addresses Claude asks for; it can't see where
a link inside a page leads, so the desk's written rules still apply.
"""
import json
import sys
from urllib.parse import urlparse

ALLOWED = ("janeapp.com", "jane.app")


def urls(node, key=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from urls(v, str(k))
    elif isinstance(node, list):
        for v in node:
            yield from urls(v, key)
    elif isinstance(node, str) and "url" in key.lower():
        yield node


def allowed(u):
    u = u.strip()
    if not u or u.lower() in ("about:blank", "chrome://newtab/", "chrome://newtab"):
        return True
    p = urlparse(u if "://" in u else "https://" + u)
    host = (p.hostname or "").lower()
    return p.scheme == "https" and any(host == d or host.endswith("." + d) for d in ALLOWED)


def main():
    try:
        call = json.load(sys.stdin)
    except ValueError:
        return 0
    bad = [u for u in urls(call.get("tool_input", {})) if not allowed(u)]
    if bad:
        sys.stderr.write("Blocked: the Jane desk only opens Jane's own site. Not allowed: %s\n" % bad[0][:120])
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
