---
name: hunt-cors
description: CORS — origin reflection, null origin, preflight abuse, wildcard detection. Establishes whether credentialed cross-origin reads are actually possible.
---

# CORS ASSESSMENT

**Core:** the only question that matters is whether a hostile origin can read
an authenticated response. A reflected `Origin` without `Access-Control-
Allow-Credentials: true` is not exploitable and must not be reported.

## DETECTION
```bash
curl -s -I -H "Origin: https://evil.com" "https://target.com/api/userinfo" | grep -i "access-control"
# ACAO reflects evil.com AND ACAC: true → credentialed read is possible
curl -s -I -H "Origin: null" "https://target.com/api/userinfo" | grep -i "access-control"
# Also check the OPTIONS preflight response, which is what the browser enforces
curl -s -X OPTIONS -H "Origin: https://evil.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: authorization" \
  "https://target.com/api/userinfo" -D- -o /dev/null
```

## WHAT ACTUALLY MATTERS
```
Origin reflected + ACAC: true + sensitive response  → exploitable
Origin reflected + ACAC absent/false                 → NOT exploitable
ACAO: *  (no credentials)                            → NOT exploitable on authed data
Null origin + ACAC: true                             → exploitable from a sandboxed iframe
Trusted subdomain list + wildcard                    → check which hosts are actually trusted
HTTP endpoint missing origin check                   → may bypass an HTTPS-only policy
```

## PROOF (minimum sufficient)

To confirm the read, show the response body actually crosses origins under
`withCredentials` — a PoC page plus the returned payload. **Do not then use
the stolen data to act** (no account takeover, no state change). A single
demonstrated cross-origin read is the complete finding.

## REPORTING NOTES
- Report the credentialed read and the data it exposes. That is the severity.
- Where it *could* compound with XSS on a trusted subdomain, note it as a
  compound-risk line; do not go find the XSS to justify a higher severity.
- `Access-Control-Allow-Origin: *` on public, non-credentialed endpoints is
  correct behavior — reject it (Gate 6).

---

## THE COMPOUND RISK — CORS `*` + UNAUTHENTICATED API

`Access-Control-Allow-Origin: *` on its own is *not* a finding when the
endpoint serves no credentialed data. But it becomes critical when paired
with another weakness, and this pairing is more common than it should be.

**The pattern:**
```
API accepts writes without authentication
  AND returns Access-Control-Allow-Origin: *
  → any website on the internet can make authenticated admin calls
```

This is not a theoretical chain. On a live target, an unauthenticated
`POST /api/admin/products` that returns `ACAO: *` means a malicious
website can create, modify, or delete products in every visitor's browser
session — with the victim's IP, from the victim's network, with no
credential needed. The CORS header turns a server-side auth failure into
a client-side exploit that any site can trigger.

**Test for it specifically:**
```bash
# After finding an unauthenticated write endpoint, check the CORS header
curl -s -I -H "Origin: https://attacker.com" \
  "https://target.com/api/admin/products" | grep -i "access-control"
```

**If ACAO is `*` (or reflects the origin) on an unauthenticated write
endpoint, report it as a compound finding.** The base finding is the
missing auth; the compound risk is that the missing auth is reachable
from any origin. This is the difference between a Critical that one team
fixes and a Critical that gets a security advisory.

**Do not build the exploit page.** Report the header combination and the
endpoint. The owner can reproduce it in one curl command.
