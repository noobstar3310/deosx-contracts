# X-Ray Report

> DEOS-X Tranche Vault | 517 nSLOC in scope (612 incl. `src/testnet/`) | 70d5239 (`feat/role-after-login`) | Foundry | 06/10/26

---

## 1. Protocol Overview

**What it does:** A USDT vault that places deposits into three fixed-size tranches in order, mints a non-transferable 1:1 LP per tranche, and lets a Safe multisig deploy the capital and pay withdrawals with interest it decides by hand.

- **Users**: Whitelisted investors (deposit, request, cancel); a portal backend key (operator: whitelist, introducer); the Safe (everything that moves money).
- **Core flow**: `deposit` → `requestWithdraw` (records the hold-time split) → Safe `fulfillWithdraw(id, interest)` → Safe `payIntroducerFee`.
- **Key mechanism**: Waterfall T1 (2M) → T2 (3M) → T3 (15M); T1/T2 never reopen, T3 reopens on payout. Per-tranche capital and interest pots; no on-chain interest maths (per spec).
- **Token model**: USDT (6 dp) in and out; `dxT1/dxT2/dxT3` (`TrancheToken`) minted on deposit, burned on payout, never transferable.
- **Admin model**: A Safe owns the vault (`Ownable2Step`, renounce disabled); operators are appointed by the Safe. No timelock.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault | DeosxVault | 482 | Tranches, positions, requests, pots, payouts, roles |
| LP token | TrancheToken | 35 | Vault-only mint/burn, non-transferable receipt |
| *Out of scope (Sepolia only)* | TestTether, SepoliaFaucet | 95 | Test USDT and ETH faucet |

### How It Fits Together

The core trick: LP is a 1:1 capital receipt, and every unit of it is tracked as a dated position so the Safe can price interest off-chain from a split frozen at request time.

### Deposit

```
DeosxVault.deposit(amount, minPieces)          [nonReentrant, whenNotPaused]
  ├─ whitelist check, _pull() → USDT.safeTransferFrom   *credits balance delta*
  ├─ minimum: opening if capitalOf == 0, else top-up; exempt if == total room
  ├─ _place(received) → pieces[3]                *T1 room, then T2, then T3*
  ├─ pieces[i] ≥ minPieces[i]                    *slippage guard*
  ├─ per piece: push Position{amount, now}, _capitalIn, taken, capital
  └─ TrancheToken.mint(wallet, piece)            *after books are final*
```

### Request / cancel

```
DeosxVault.requestWithdraw(tranche, amount)     [whenNotPaused, no whitelist check]
  ├─ openRequestOf == 0, amount ≤ _capitalIn
  ├─ _snapshot(): walk positions from _head      *split under-half / half / full at now*
  └─ reserved[w][t] = amount, _pending.add, openRequestOf = id
DeosxVault.cancelWithdraw(id)                  *owner only, works while paused*
```

### Payout and fee

```
DeosxVault.fulfillWithdraw(id, interest)        [Safe, nonReentrant]
  ├─ _requireCapital(amount)                     *balance − totalInterestPot*
  ├─ _spendInterest(tranche, interest)           *that tranche's pot only*
  ├─ _consumeOldest(): advance _head, trim head  *removes exactly the snapshotted units*
  ├─ books −amount; T3 taken −amount; status Paid; fee Due if introducer recorded
  ├─ TrancheToken.burn(investor, amount)
  └─ USDT.safeTransfer(investor, amount + interest)
DeosxVault.payIntroducerFee(id, fee)            *once; pays r.introducer from the pot*
```

### Capital deployment

```
DeosxVault.transferOut(to, x)   [Safe]  *x ≤ capital cash; deployedCapital += x*
DeosxVault.returnCapital(y)     [Safe]  *pull; deployedCapital −= received*
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Vault (custodial, admin-priced)** with **Withdrawal-queue** characteristics

Deposit/redeem against a 1:1 receipt with funds deployed off-vault by the owner matches the vault profile, but there is no share price, strategy or oracle, so inflation/oracle threats do not apply; the request → Safe-payout queue adds liquid-staking-style withdrawal-queue concerns.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Owner (Safe) | Trusted | All instant, no timelock, not pausable: `transferOut` uncapped to any address, `fulfillWithdraw` with any interest ≤ pot, `payIntroducerFee`, pots in/out, `setOperator`, `setMinimums`, pause. Also an operator. Two-step handover; renounce reverts. |
| Operator | Bounded (cannot move funds) | `setWhitelisted`, `setIntroducer` — instant, work while paused; changes the introducer future requests record. Removed by `setOperator(op, false)`. |
| Whitelisted investor | Bounded (own capital only) | `deposit`; then `requestWithdraw` / `cancelWithdraw` (no whitelist needed to leave). |
| Introducer | Untrusted recipient | Receives fees the Safe chooses to pay; no calls. |

**Adversary Ranking:**

1. **Compromised or careless Safe signers** — every outflow (capital, interest, fees) is a Safe decision with no on-chain cap, so signer error or compromise is the dominant risk.
2. **Compromised operator key** — can whitelist arbitrary wallets and redirect introducer attribution on future requests.
3. **Malicious investor** — can shape its own position list, request timing and amounts to stress gas bounds or the Safe's off-chain pricing.
4. **Front-running depositor** — can race the last room in T1/T2 or T3 reopenings.
5. **Token-level actor (Tether)** — transfer fee, blacklist of the vault, or seizure moves balances outside the vault's books.

See [entry-points.md](entry-points.md) for the full entry point map.

### Trust Boundaries

- **Safe → vault funds** — multisig only; no timelock or per-call cap; `transferOut:316` can send all capital cash anywhere instantly. Deploy script checks only that the Safe has code (`Deploy.s.sol`).

- **Operator → investor set** — `setWhitelisted:421` / `setIntroducer:433` are instant and unpausable; damage is bounded to who can deposit and whom fees are recorded for. *Git signal: role-separation logic changed in `a6b8e8a` and `f9f7f50` (5 Oct).*

- **Investor → vault** — permission is the whitelist plus state (own request, own capital); `requestWithdraw`/`cancelWithdraw` touch no tokens.

- **Vault → USDT** — `SafeERC20` throughout, balance-delta on inflows only; outflows assume no transfer fee.

### Key Attack Surfaces

- **Safe operational powers with no on-chain limit** &nbsp;&#91;[I-19](invariants.md#i-19), [E-3](invariants.md#e-3)&#93; — `transferOut:316` ignores reserved capital and `fulfillWithdraw:346` takes any `interest` ≤ pot; worth confirming the off-chain Safe procedures (README recipes) are the intended and only control.

- **Capital-side cash derived from `balanceOf`** &nbsp;&#91;[I-5](invariants.md#i-5), [G-13](invariants.md#g-13), [I-21](invariants.md#i-21)&#93; — `_capitalCash:648` is `balance − totalInterestPot` with no capital counter; worth tracing every outflow under a non-zero Tether fee and after an unsolicited transfer.

- **Position list walking and head bookkeeping** &nbsp;&#91;[I-3](invariants.md#i-3), [I-15](invariants.md#i-15), [G-9](invariants.md#g-9)&#93; — `_snapshot:598` and `_consumeOldest:618` must remove exactly the units that were snapshotted; worth checking boundary pieces, partial heads, and the gas bound that rests on `topUpMinimum ≥ 5,500` (KNOWN_ISSUES §2).

- **Request / reservation lifecycle** &nbsp;&#91;[I-9](invariants.md#i-9), [I-10](invariants.md#i-10), [I-11](invariants.md#i-11)&#93; — one open request per wallet across tranches, `reserved` zeroed on cancel and payout; worth checking deposits while a request is pending and cancel during pause.

- **Deposit minimum exemption and placement guard** &nbsp;&#91;[G-6](invariants.md#g-6), [G-7](invariants.md#g-7), [I-7](invariants.md#i-7), [I-8](invariants.md#i-8)&#93; — `received != _totalRoom()` at `:214` waives the minimum, and T3 room changes on every T3 payout; worth checking what sizes the exemption admits and races around reopened T3 room.

- **Introducer recording and fee lifecycle** &nbsp;&#91;[I-12](invariants.md#i-12), [I-17](invariants.md#i-17), [I-18](invariants.md#i-18)&#93; — introducer copied at request time (`:263`), fee flagged Due at payout with no pot reservation (`:368`); worth tracing operator timing around `requestWithdraw`.

- **Staff / investor separation** &nbsp;&#91;[I-14](invariants.md#i-14), [G-18](invariants.md#g-18), [G-20](invariants.md#g-20), [G-22](invariants.md#g-22)&#93; — enforced across `setOperator`, `setWhitelisted`, `transferOwnership` via `_isInvestor:566`; worth confirming no ordering (pending handover, operator removal) leaves a gap.

### Protocol-Type Concerns

**As a Yield Vault:**
- No share price: LP is fixed at 1 USDT (`fulfillWithdraw:376`), so loss socialisation is absent by design; worth confirming there is no path where `capital` exceeds what can ever be repaid on-chain (spec puts losses out of scope).
- `TrancheToken` inherits OZ `ERC20`; `transferFrom` reverts with `ERC20InsufficientAllowance` (allowance is always 0) before reaching `_update:50`; worth confirming no other inherited path (e.g. a 0-value `transferFrom`) moves LP.

**As a Withdrawal queue:**
- `pendingRequests()` returns an unordered `EnumerableSet` (`:517`); payout order and pro-rata under a shortfall are entirely the Safe's choice (KNOWN_ISSUES §4).

### Temporal Risk Profile

**Deployment & Initialization:**
- Tier thresholds, tranche sizes and USDT are immutable (`:89-93`); `Deploy.s.sol` hard-fixes mainnet values and refuses other chains — mitigated.
- The Safe must appoint operators after deploy; until then only the Safe can whitelist — no exposure, ordering only.

**Market Stress:**
- A withdrawal run is bounded by capital cash; with capital deployed, payouts revert `InsufficientCapital` until `returnCapital` — unmitigated on-chain by design.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **USDT (Tether)** — via `DeosxVault._pull`, `safeTransfer` in 4 outflows
> - Assumes: no transfer fee on outflows; vault not blacklisted; no balance changes outside vault calls
> - Validates: balance delta on inflows (`_pull:549-553`); `SafeERC20` for missing return values
> - Mutability: upgradeable/governed by Tether (fee switch, blacklist, destroy)
> - On failure: blacklisted vault freezes everything; fee makes recipients receive less than recorded

> **OpenZeppelin v5 (submodule)** — `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeERC20`, `EnumerableSet`, `ERC20`
> - Unmodified submodule; standard behaviour assumed.

**Token Assumptions** *(unvalidated only)*:
- USDT outflows: assumes fee = 0 — impact if violated: `deployedCapital`, payouts and fees overstate what arrived ([I-21](invariants.md#i-21)).

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> - **26 Enforced Guards** (`G-1` … `G-26`)
> - **21 Single-Contract Invariants** (`I-1` … `I-21`) — 6 Conservation, 9 Bound, 1 Ratio, 3 StateMachine, 2 Temporal
> - **2 Cross-Contract Invariants** (`X-1`, `X-2`)
> - **3 Economic Invariants** (`E-1` … `E-3`)
>
> On-chain=**No** blocks: I-5, I-17, I-18, I-19, I-21, E-3 — all match items already in `KNOWN_ISSUES.md`.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` — audit scope, integration, admin recipes, errors, deploy |
| NatSpec | Thorough | `@notice`/`@dev` on nearly every external function and key internals |
| Spec | Present | `docs/design-v2.md` |
| Known issues | Present | `KNOWN_ISSUES.md` — accepted behaviours and the 5 Oct pre-audit fixes |
| Inline Comments | Thorough | Intent stated at every non-obvious step |

README test-suite count and LP `transferFrom` error now match the code.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 16 | File scan |
| Test functions | 153 run incl. 12 invariants (151 pass, 2 fork tests skip without RPC) | `forge coverage` |
| Line coverage | DeosxVault 100% (264/264), TrancheToken 100% | `forge coverage` |
| Branch coverage | DeosxVault 96.1% (49/51), TrancheToken 100% (2/2) | `forge coverage` |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | ~120 | DeosxVault, TrancheToken, Deploy script |
| Fork | 2 | Sepolia + mainnet USDT (blacklisted payee paid) |
| Stateless Fuzz | 4 | Deposit waterfall, request amounts, request/fulfill, random-ops model |
| Stateful Fuzz (Foundry) | 12 invariants | 256 runs × depth 100, `fail_on_revert = true`; 16 handler actions incl. whitelist, introducer, minimums, pause, ownership handover, direct transfers |
| Stateful Fuzz (Echidna / Medusa) | 0 | none |
| Formal Verification | 0 | none |

### Gaps

- **Handler inputs are bounded to valid calls** (0 reverts by design under `fail_on_revert`); revert paths are covered by unit tests instead. A Tether transfer fee is not switched on during invariant runs (unit tests cover fee-on pulls).
- No formal verification or second fuzzer for the position/head arithmetic (I-3, I-15), which is the most intricate code.

---

## 6. Developer & Git History

> History below is from the product repo (`deosx-yield`, branch `feat/role-after-login` at `70d5239`), where these contracts were developed: 19 source-touching commits over 12 days (24 Sep → 6 Oct 2026). This repo starts from that code.

### Contributors

| Author | Commits (repo) | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| noobstar3310 | 63 | +1698 / −921 | 100% |
| Ky0 | 28 | 0 | 0% (frontend) |
| Brutt09 | 12 | 0 | 0% (frontend) |
| teiza-dev | 1 | 0 | 0% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors (contracts) | 1 | Single developer |
| Merge commits | 10 of 104 (10%) | Some PR flow, but not for every contract change |
| Repo age | 2026-09-24 → 2026-10-06 | 12 days |
| Recent source activity (30d) | 19 commits | All contract history is "late" |
| Test co-change rate | 100% | Every source commit also touched tests |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/DeosxVault.sol | 17 | All logic; v2 rewrite on 1 Oct, role/fix changes on 5 Oct |
| src/TrancheToken.sol | 2 | `approve` revert added 5 Oct |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| f9f7f50 | 2026-10-05 | fix(contracts): close pre-audit findings in the tranche vault | 19 | access control + fund flows + tests |
| 4236cff | 2026-09-30 | feat(contracts): tranche vault skeleton, LP token and Tether mock | 14 | loosens access control |
| 1d5256c | 2026-10-01 | feat(contracts): vault v2 with capital and interest pots per tranche | 12 | >500-line rewrite |
| ad0e381 | 2026-10-01 | fix(contracts): request minimum, bounded settings, saturating capital cash | 11 | accounting change |
| f887d32 | 2026-10-01 | fix(contracts): eligibility follows each request's own slice | 11 | split/positions logic |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 18 | DeosxVault.sol, TrancheToken.sol |
| access_control | 17 | DeosxVault.sol, TrancheToken.sol |

### Security Observations

- **Single author** — noobstar3310 wrote 100% of contract lines.
- **Very young code** — v2 rewrite landed 1 Oct; last logic change 5 Oct (`f9f7f50`, `a6b8e8a`).
- **Pre-audit fixes already applied** — 6 findings closed in `f9f7f50`, each with a test in `DeosxVault.auditFixes.t.sol`.
- **No tech-debt markers** — 0 TODO/FIXME/HACK.

### Cross-Reference Synthesis

- **DeosxVault.sol is the only hotspot and holds every surface** → audit effort maps 1:1 onto one 482-nSLOC file.
- **`f887d32` + `a145749` reworked request slices** → I-3/I-15 position arithmetic is the most-churned logic and has no formal or second-fuzzer coverage.
- **I-14 (staff/investor separation) is now fuzzed** → `invariant_StaffAndInvestorsApart` runs with ownership handovers and whitelist toggles.
- **`a6b8e8a` + `f9f7f50` (5 Oct) added staff/investor separation** → I-14 is the newest invariant; worth a focused pass.

---

## X-Ray Verdict

**HARDENED** — Unit, fuzz, fork and stateful invariant tests with 100% line coverage, a current spec, KNOWN_ISSUES and a multisig owner; no formal verification keeps it below FORTIFIED.

**Structural facts:**
1. 517 nSLOC in scope across 2 contracts; non-upgradeable; no oracles or external protocols beyond USDT.
2. 151 passing tests incl. 12 Foundry invariants (2 fork tests need an RPC); DeosxVault 100% lines / 96% branches, TrancheToken 100%.
3. One developer wrote 100% of contract code over 12 days; last logic change 5 Oct 2026.
4. All money movement is owner (Safe) gated with no timelock; 6 On-chain=No invariants all correspond to documented known issues.
