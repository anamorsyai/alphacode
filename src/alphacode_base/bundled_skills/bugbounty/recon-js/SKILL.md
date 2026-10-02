---
name: recon-js
description: Client-side code analysis — download JS bundles and extract the API endpoints, GraphQL operations, and secrets that network scanning cannot see. Use on any SPA (Next.js, Nuxt, React, Angular, Vue) BEFORE generic endpoint wordlists.
---

# RECON-JS — THE BUNDLE IS THE SOURCE OF TRUTH

**Generic wordlists produce 90%+ 404s on SPAs. The JS bundle lists the
real endpoints. Analyze it first, fuzz second.**

---

## 1. ORDER OF OPERATIONS

1. Confirm the app is an SPA (view-source shows a `<div id="__next">`,
   `__NUXT__`, or a single root div plus script tags).
2. Download the bundles (section 2).
3. Extract endpoints, operations, and secrets (section 3).
4. Map them to testable targets (section 4).
5. THEN fall back to wordlists for what the bundle did not reveal.

Never skip to step 5. A 10-minute bundle pass beats an hour of 404s.

---

## 2. DOWNLOAD THE BUNDLES

```bash
# List chunk URLs from the page (works for Next.js / Nuxt / generic SPAs)
curl -s --max-time 20 "https://TARGET/" | grep -oE 'src="[^"]+\.js[^"]*"' | head -50

# Next.js: chunks live under /_next/static/chunks/ — fetch each one
curl -s --max-time 20 -o chunk.js "https://TARGET/_next/static/chunks/<file>.js"

# Embedded data: Next.js serializes page props into the HTML itself
curl -s --max-time 20 "https://TARGET/" | grep -oE '__NEXT_DATA__.*' | head -c 4000
```

Keep every response small: `head -c`, `head -50`, `--max-time 20`.
A 170KB header dump teaches nothing — filter at fetch time.

---

## 3. EXTRACTION PATTERNS

Run these against each downloaded chunk (and the HTML):

```
# API routes and fetch calls
/api/[a-zA-Z0-9/_${}.-]+
fetch\(["'`]/[^"'`]+
axios\.(get|post|put|delete|patch)\(["'`]/[^"'`]+

# GraphQL: operation names, mutations, schema hints
(mutation|query)\s+[A-Za-z0-9_]+
graphql|/graphql|__schema|__typename

# Next.js data routes (directly fetchable JSON)
/_next/data/<build-id>/<page>.json

# Secrets and keys (flag for hunt-apikey-leak, do not exfiltrate)
api[_-]?key|secret|token|password|client_secret
AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]+|xox[bap]-|sk_live_

# Source maps (full original source when left deployed)
\.js\.map
```

One pattern per pass, capped output (`sort -u | head -100`). Record
hits in the assessment notes with the chunk they came from.

---

## 4. TURN HITS INTO TARGETS

| Hit | Next step |
|-----|-----------|
| `/api/...` route | Probe directly (method, auth, IDOR — see hunt-api) |
| `/_next/data/<build>/...json` | Fetch it: exposes props/redirects without rendering |
| GraphQL operation | Send to /graphql (see hunt-graphql) |
| `__NEXT_DATA__` blob | Parse buildId, pageProps, runtimeConfig for env leaks |
| `.js.map` file | Download it: original source, comments, dead endpoints |
| Hardcoded key/token | Validate capability minimally, report via evidence-locker |

Every endpoint that came from the bundle outranks any wordlist guess.
Test bundle-derived endpoints first (see runbook target prioritization).

---

## 5. RULES

- Scope file applies to bundle URLs too (see scope skill).
- Do not publish or replay secrets beyond minimal capability proof.
- Save interesting chunks under `evidence/` with a manifest entry
  (see evidence-locker) — bundles rotate between deploys.

---

## 6. REAL-WORLD EXECUTION — WHAT ACTUALLY WORKS

These come from engagements where the bundle was the *only* thing that
opened the target. Generic wordlists produced 90%+ 404s on every one.

### 6.1 The bundle is the highest-yield first step — always

On three separate SPA targets, the JS bundle contained the real API
surface: endpoint paths, auth configuration, hardcoded secrets, and
sometimes the admin credentials. In one case the bundle revealed an
`/api/v1` prefix that no wordlist contained, and the API was fully
unauthenticated. **Analyse the bundle before running any wordlist.**
A 10-minute bundle pass beats an hour of 404s.

### 6.2 Chain the chunks — do not stop at the entry point

SPAs ship as a main bundle plus many lazy-loaded chunks. The entry bundle
often only references the chunk filenames. Extract those too:

```bash
# Chunks referenced from the entry bundle
grep -oE '[a-zA-Z0-9_/.-]+\.js' entry.js | sort -u

# Next.js: the chunks directory is predictable
curl -s "https://TARGET/_next/static/chunks/" 2>/dev/null
# or fetch each chunk path found in the HTML's script tags
```

A single endpoint may live in a chunk loaded only on a specific page.
**Run the extraction patterns from section 3 against every chunk, not
just the main one.** Missing a chunk is the most common way to miss the
finding.

### 6.3 Parse `__NEXT_DATA__` properly

The HTML contains a JSON blob. Do not `grep` it into a file and eyeball
it — parse it:

```bash
curl -s "https://TARGET/" | python3 -c "
import sys,json,re
raw=sys.stdin.read()
m=re.search(r'__NEXT_DATA__\s*=\s*(\{.*?\})</script>', raw, re.S)
if m:
    d=json.loads(m.group(1))
    print(json.dumps(d.get('props',{}), indent=1)[:4000])
"
```

`buildId`, `runtimeConfig`, and `pageProps` are the three keys that
leak environment-specific data. `runtimeConfig` in particular is where
publicRuntimeConfig values land — those are *intended* to be public but
often contain API base URLs and feature flags that should not be.

### 6.4 Source maps are the full source

A `.js.map` file contains the original source, comments, and dead code.
When one is deployed, download it and extract the original endpoints —
they include routes removed from the live bundle but still referenced
in old code paths.

### 6.5 The grep character-class trap

`grep -oE '[a-zA-Z0-9_/.-]+'` fails silently with "Invalid range end"
because `-` in the middle of a class is a range operator. Place `-` at
the end of the class, or escape it:

```bash
# WRONG — fails silently, returns nothing
grep -oE '/api/[a-zA-Z0-9/_${}.-]+' file.js

# RIGHT — dash at the end
grep -oE '/api/[a-zA-Z0-9/_${}.]+-' file.js
# or use Python which does not have this gotcha
```

A silent grep failure looks exactly like "no endpoints found". **Always
verify a grep returns the literal pattern you expect on a known-good
line before trusting a null result.**

### 6.6 Secrets in the bundle — validate, do not exfiltrate

A hardcoded `api_key` in the bundle is a finding. To prove it is live,
make one authenticated call with it against a *non-destructive* endpoint
(read-only, your own account, or a public status endpoint). Do not pull
customer data. Record the capability, not the volume.

### 6.7 When the bundle reveals an API that no longer needs auth

The most valuable discovery pattern: the bundle shows the API was built
before auth was added, or auth is enforced only in the UI. Test the
bundle-derived endpoints **unauthenticated** first. A 200 without a
token on a `/api/v1/admin/*` route is worth more than any wordlist
guess. See `hunt-api` and `control-verification` for the follow-up tests.
