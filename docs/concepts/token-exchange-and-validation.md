# Token Exchange & Token Validation in Managed-Mode FTS

A short reference for how this testbed uses OAuth2 token-exchange ([RFC 8693](https://datatracker.ietf.org/doc/html/rfc8693))
with FTS managed mode and why storage endpoints validate tokens **offline**
rather than via introspection.

## Is token-exchange used in managed mode? Yes.

Managed FTS mode is built on RFC 8693 token-exchange. The flow:

1. Rucio mints short-lived **storage tokens** (per-RSE audience) by exchanging
   the transfer-owning account's stored OIDC **subject token**. These tokens
   carry `offline_access`.
2. Rucio submits the FTS job with those source/destination tokens (plus an
   FTS-server token).
3. FTS performs its own exchange (the `TOKEN_PREP` step) to obtain **refresh
   tokens**, then refreshes the storage tokens on demand for the job lifetime.
4. Storage endpoints validate each presented token at transfer time.

The key property: **FTS owns the token lifecycle.** Rucio hands over
short-lived tokens; FTS keeps them fresh. This is the opposite of *unmanaged*
mode, where Rucio mints long-lived per-file tokens sized to cover the whole
transfer and FTS does no exchange and no refresh.

## Token-exchange in a nutshell

Token-exchange lets a service obtain a **new, narrower token derived from an
existing one** — different audience, reduced scope, separate lifetime — while
preserving the original subject (`sub`). Instead of handing a broad, long-lived
user token to a downstream service, you exchange it for a purpose-specific,
short-lived token addressed to exactly the resource that needs it.

```text
user subject token  ──exchange──▶  audience = storage-X
(aud: rucio,                       scope    = storage.read storage.modify
 offline_access)                   lifetime = minutes
```

This is the modern, idiomatic pattern for **"a service acting on behalf of a
user"** — delegated access, data transfers, microservices, federated
infrastructure. It is generally considered more secure than distributing
long-lived bearer tokens, because it shifts the security model from
*"central revocation and control"* toward *"short lifetimes and constrained
delegation."*

### Why it's preferred over long-lived tokens

| Long-lived token               | Token exchange                    |
| ------------------------------ | --------------------------------- |
| One token valid for days/weeks | Short-lived derived tokens        |
| Broad permissions accumulate   | Narrow audience/scope per use     |
| Hard to distribute safely      | Safe to delegate                  |
| Revocation is critical         | Expiry bounds the damage window   |
| Large blast radius if stolen   | Small blast radius                |
| Reused everywhere              | Purpose-specific, minted per need |

This is now a dominant design across OAuth2/OIDC ecosystems, cloud APIs,
SciTokens/WLCG, service meshes and zero-trust architectures. A common pattern
is **short-lived exchanged JWTs + offline validation**, rather than long-lived
centrally-introspected bearer tokens.

## Validation: offline JWT verification vs. introspection

Exchanged tokens are commonly issued as **self-contained signed JWTs** and are
often treated as delegated credentials independent of an interactive user
session. That makes offline validation a natural fit.

| Aspect                                            | Offline JWT validation                                                                                                                                          | Token introspection                                         |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| What it does                                      | Validator checks the JWT locally: signature + claims (`iss`, `aud`, `exp`, `nbf`)                                                                               | Validator asks the issuer "is this token active right now?" |
| Network dependency                                | None, once JWKS keys are cached                                                                                                                                 | Live call to the IdP on every validation                    |
| Speed / scale                                     | Very fast; scales well                                                                                                                                          | Slower; adds latency and load on the IdP                    |
| IdP temporarily down?                             | Keeps working as long as the cached JWKS covers the token's `kid` (already-issued tokens still validate; only matters if a *new* key is used during the outage) | Fails — validation depends on issuer availability           |
| Supports exchanged / delegated tokens (RFC 8693)? | Yes — this is the common model                                                                                                                                  | Depends on IdP implementation and token model               |
| Revocation awareness                              | None directly — **mitigated by short lifetimes** (revocation latency is bounded by `exp`)                                                                       | Yes — issuer can reject a revoked token immediately         |
| Security model                                    | Trust cryptographic signature + short expiry                                                                                                                    | Trust the issuer's real-time state                          |
| Typical token lifetime                            | Short-lived access tokens (WLCG profile: 5 min – 6 h)                                                                                                           | Can support longer-lived / session-bound tokens             |
| Common in WLCG / SciTokens / cloud data APIs?     | Yes                                                                                                                                                             | Less common for high-scale data access                      |
| Best fit                                          | Distributed storage / data-transfer systems                                                                                                                     | Interactive, session-oriented web applications              |

### Which validation method complements token-exchange?

In practice, **offline validation** strongly complements token-exchange for
distributed storage and transfer systems. Exchanged JWTs are typically designed
to be verified locally — the receiver only needs the signature, `exp`/`nbf`,
`iss`, `aud` and scopes.

While RFC 8693 does not prohibit introspection, many exchanged-token
deployments intentionally avoid centralized token state. In those systems,
introspection may be unreliable or incompatible for exchanged tokens because
the authorization server does not treat them as active session-backed tokens.

For example, some IdPs (including common Keycloak configurations) may return:

```json
{ "active": false }
```

for a cryptographically valid exchanged JWT.

This is not necessarily a protocol violation or misconfiguration — it reflects
a different token model. As a result, this testbed's storage validators
(XRootD SciTokens and the Teapot proxy) validate exchanged tokens offline
against the issuer's JWKS rather than relying on `/introspect` or `/userinfo`.

### Is "offline is better" always true? No — it's a bounded tradeoff.

Offline validation is the right choice **here** because:

1. exchanged tokens are short-lived delegated JWTs intended for distributed
   verification and
2. WLCG token lifetimes are short, so the lack of revocation checking is
   bounded by expiry.

For a long-lived, session-bound, interactively-revocable token,
**introspection may be the safer choice.** The validation method should follow
the token type, deployment model and lifetime policy rather than a blanket
preference.

## The one thing you must get right

Offline validation is only safe if validators **strictly** check, on every
request:

* `signature` (against the issuer's JWKS)
* `exp` and `nbf`
* `iss`
* `aud` (the token is addressed to *this* endpoint)
* scopes (the operation is authorized)
* **key rotation** — refresh the JWKS when an unknown `kid` appears, so an IdP
  key rollover neither starts rejecting valid tokens nor keeps trusting a
  retired key

Skip any of these and "offline validation" quietly degrades into "accept
anything signed once." Done correctly, short-lived exchanged JWTs with strict
offline validation are a strong, modern security model.

## Summary

* Managed FTS mode **uses RFC 8693 token-exchange**; FTS owns the token
  lifecycle (exchange + refresh). Tokens must carry `offline_access`.
* Token-exchange is the modern approach for service-acting-on-behalf-of-a-user
  and for long-running transfers — narrow, short-lived, purpose-specific
  tokens instead of broad long-lived ones.
* In distributed JWT ecosystems such as WLCG/SciTokens, token-exchange
  strongly complements offline validation.
* Introspection is still possible in principle, but many exchanged-token
  deployments intentionally avoid centralized token state, making
  introspection unsuitable or unreliable in practice.
* A common modern pattern is **short-lived exchanged JWTs + strict offline
  validation** — with the explicit tradeoff of trading instant revocation for
  short lifetimes.
