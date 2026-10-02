---
name: credential-attack
description: Password spray methodology for bug bounty — when to do it vs web-vuln hunting, the wordlist-gen + breach-check + osint-employees + spray pipeline, mode selection (http-form / oauth / o365 / okta), rate-limit + lockout tactics, legal guardrails, success detection, and the spray → authenticated /hunt chain pattern.
---

# CREDENTIAL ATTACK PIPELINE

Real-world initial-access vector. Verizon DBIR consistently ranks Stolen Credentials in the top 3 incident types. Most BB hunters skip this because they only try `rockyou.txt` and get rate-limited.

**Core principle:** humans pick lazy passwords. `{CompanyName}{Year}!`, `{ProductName}{Season}`, `{City}123`. Harvesting company-specific vocabulary before spraying is what makes the hit-rate go from 0.01% to 1%+.

---

## WHEN TO RUN CREDENTIAL ATTACK

Credential attack is a **parallel branch** to `/hunt`, not a replacement:

```
/recon ──┬──▶ /hunt (web vuln scan) ──┐
         │                             ├──▶ /validate ──▶ /report
         └──▶ /wordlist-gen → ... → /spray ──┘
```

**Run it when:**
- Target has a discoverable login endpoint (web form / O365 / Okta / OAuth)
- Program scope **explicitly permits** authentication testing or credential testing
- You can stomach a 30-min-to-multi-hour run (with conservative defaults)

**Skip it when:**
- Program policy lists "credential stuffing", "brute force", or "password attacks" as out-of-scope
- Target only has SSO via a provider you don't control
- Login endpoint is rate-limited so aggressively that even 1 attempt/30min triggers alerts

**KILL signals (don't even start):**
- No login surface in recon output
- WAF (Cloudflare with Bot Management, Akamai) on every auth endpoint
- Program runs an active red-team — they'll see your spray immediately
- You don't have a clean wordlist yet (running rockyou.txt is a waste of lockouts)

---

## THE 4-STAGE PIPELINE

```
/wordlist-gen ──▶ /breach-check ──▶ /osint-employees ──▶ /spray
 (company words)    (rank by HIBP)    (real usernames)    (live attempts)
```

### Stage 1 — Wordlist Generation

Crawls the target website with `cewler`, deduplicates, applies hashcat rules to mutate.

**Mode selection:**

| Mode | Rules | When |
|------|-------|------|
| `minimal` | top10_2025 (10 rules) | Cautious spray, paranoid program |
| `balanced` *(default)* | best66 (66 rules) | Standard — best signal/noise |
| `aggressive` | OneRuleToRuleThemAll (52k) | **Offline cracking only**, NOT spray |

**Filter selection:**

| Filter | When |
|--------|------|
| `strict` *(default)* | API-doc-heavy sites. Drops CSS hex colors, URL slugs, random API tokens |
| `loose` | Marketing sites without API examples |

### Stage 2 — Breach Check

Sends only first 5 chars of SHA-1 to HIBP (k-anonymity). **Free, no API key, full passwords never leave your machine.**

**Breach-count interpretation:**

| Range | Meaning | Spray strategy |
|-------|---------|----------------|
| **0** | Never leaked | Could be company-specific OR truly random |
| **1-1000** | "Sweet spot" — proven human use, not yet in every spray list | **Prioritize** |
| **1k-1M** | Mainstream | Usually already tried by previous attackers |
| **>1M** | Generic (`password`, `123456`) | Skip — every WAF expects these |

### Stage 3 — OSINT Employee Enumeration

`theHarvester` (search engines + CT logs) → derive names from email local-parts → `username-anarchy` permutations.

**Realistic expectations:**

| Target type | Expected emails | Expected names |
|-------------|----------------|----------------|
| US/EU SaaS | 5-50 | depends |
| State utility | **0** | 0 |
| Local SME | 0-10 | 0-5 |

### Stage 4 — The Spray

**Mode selection:**

| Mode | Use case | Engine |
|------|----------|--------|
| `http-form` | Custom login page (most BB targets) | Pure Python urllib |
| `oauth` | OAuth password grant (`grant_type=password`) | Pure Python urllib |
| `o365` | Microsoft 365 / Azure AD | `trevorspray` |
| `okta` | Okta SSO | `trevorspray` |

**Hard guards (no override possible without `--i-understand`):**
1. **Typed-hostname confirmation** — you must type the target hostname back
2. **Lockout warning** — calculates per-user failed-attempt count
3. **Audit log JSONL** — every attempt logged (passwords as SHA-256 prefix only)
4. **Spray order** — `pass[i] × all_users` per round (not brute per-user)

---

## SPRAY ORDER — WHY IT MATTERS

```
WRONG (brute-force order, will lockout):
  alice: pass1, pass2, pass3, ...  ← alice gets 8 failed attempts in seconds
  bob: pass1, pass2, pass3, ...

RIGHT (spray order, distributes failures):
  Round 1: pass1 → alice, bob, charlie (1 failed each)
  [delay 30 min]
  Round 2: pass2 → alice, bob, charlie (2 failed total each)
```

Default rate-limit: `--delay 1800 --jitter 60` (30 min/round + ±60s).

---

## SUCCESS DETECTION

### http-form mode (checked in order):
1. `--success-regex <body-regex>` matches → success
2. `--fail-regex` set AND body does NOT match → success
3. HTTP redirect to non-login path → success (heuristic)
4. **Always supply `--fail-regex "Invalid|incorrect|wrong"` for production sprays**

### oauth mode:
- HTTP 200 with `"access_token"` in JSON → success
- HTTP 4xx → fail (unambiguous)

---

## REPORTING CREDENTIAL TESTING

Report what you proved, at the severity it supports:

```
Rate limit absent on login          → Low/Medium, on its own merits
A known-credential pattern accepted → Medium, note the weak-credential issue
A single test account you own works → Info, or not reportable
```

If the program requires demonstrating account impact, ask the user before
going further. Do **not** use recovered credentials to browse other users'
data, and do not attempt privilege escalation with them — that crosses from
"credential testing" into unauthorized access, and it is the single easiest
way to turn an authorized engagement into an incident.

Where authenticated testing would clearly change the answer, say so as a
recommendation ("with a test account for role X we could confirm whether
this reaches admin data") and let the user or program grant it.

---

## REAL-WORLD BRUTE FORCE — SMALL LISTS WIN

The default assumption in this skill is that credential attacks need
large wordlists and long runtimes. That is backwards for the most
common real-world case.

**An 8-digit numeric password was cracked with a 47-word list in
seconds.** The list was not a breach corpus — it was company vocabulary:
`admin`, `password`, `12345678`, `ebla`, `trading`, `company`, `2024`,
`2025`, plus common defaults. The password was `12345678`, tried at
position 6 of round 1.

### The lesson: build the list from the target's own words

A generic `rockyou.txt` spray against a trading platform gets
rate-limited and produces nothing. A 50-word list built from the
company name, product names, year, and common defaults cracks weak
admin credentials before the first lockout threshold is reached.

**Wordlist generation order:**
1. Company name + variants (lowercase, capitalized, with/without space)
2. Product/service names from the website
3. Current year ± 2 years
4. Common defaults: `admin`, `password`, `123456`, `12345678`,
   `1234567`, `admin123`, `letmein`, `welcome`
5. Company name + year + `!`/`@`/`123` suffixes
6. Numeric sequences (7-8 digits) — weak PINs are extremely common
   for admin accounts on small platforms

**Total target size: under 100 words.** A larger list is not more
likely to hit — it is more likely to trigger rate limiting.

### Spray order matters more than list size

Spray one password across all users, then move to the next password.
With a 50-word list and a 1-user target, this is identical to brute
force — but the principle still applies with multiple accounts.

### Default-credential check before any wordlist

The single highest-probability test is not a wordlist at all: try the
literal defaults first, in order, with no delay:
```
admin / admin
admin / password
admin / 123456
admin / 12345678
admin / admin123
```

These five attempts take seconds and crack a large fraction of
admin accounts on small platforms. **Run this before generating any
wordlist.** If it hits, the credential-attack pipeline is done —
document and move to authenticated testing.

### Rate-limit behaviour is the finding, not an obstacle

If the login endpoint returns 429 after N attempts, record N. That is
a Low/Medium finding on its own and it tells you whether a longer
spray is feasible. Do not try to defeat the rate limit — characterise
it and stop (see `control-verification`).

### After a hit: stop, do not explore

A cracked credential is the end of the credential-attack phase. Do
not use it to browse other users' data or attempt privilege
escalation — that crosses from authorized credential testing into
unauthorized access. Document the credential class (weak admin
password, default creds, numeric PIN) and let the owner know. If
authenticated testing is needed to confirm impact, ask the user.

---

## LEGAL GUARDRAILS

Before running `/spray` against ANY target, verify:
1. **Program policy explicitly allows credential testing**
2. **The wordlist does not contain plaintext breach data** (HIBP hash-prefix is fine; plaintext breach corpus is not)
3. **Stop on first hit by default**
4. **Report the lockout impact** with timestamps from the audit log

---

## OPERATIONAL CHECKLIST

Before pressing enter on `/spray`:
- [ ] `/scope <login-host>` returns IN SCOPE
- [ ] Program policy reviewed for credential-testing rules
- [ ] Wordlist filtered (`--filter strict`) and HIBP-ranked (`--max-count 1000000`)
- [ ] Usernames file has REAL usernames (from OSINT)
- [ ] Default delay (`--delay 1800 --jitter 60`) unless program permits faster
- [ ] `--dry-run` passed once to verify post-data template

During spray:
- [ ] Monitor audit log for HTTP 429 / 503 / response-time spikes
- [ ] If status codes get weird → assume detection and abort

After spray:
- [ ] If hit: STOP, document the find, do NOT log in further
- [ ] If lockouts likely happened: notify program with audit log timestamps
