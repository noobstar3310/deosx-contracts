# Invariant Map

> DEOS-X Tranche Vault | 26 guards | 26 inferred | 6 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (address(usdt_) == address(0)) revert ZeroAddress()` · `DeosxVault.sol:177` · USDT is immutable; a zero token would brick every flow forever.

#### G-2
`if (halfTierAfter_ == 0 || fullTierAfter_ <= halfTierAfter_) revert InvalidConfig()` · `DeosxVault.sol:178` · Keeps the immutable tier clock ordered so `_tierBps` yields 0 → 50% → 100% monotonically.

#### G-3
`if (topUpMinimum_ == 0 || openingMinimum_ < topUpMinimum_) revert InvalidConfig()` · `DeosxVault.sol:179` · Seeds the minimum-ordering invariant (I-13) at deploy time.

#### G-4
`if (sizes[i] == 0 || sizes[i] > type(uint128).max) revert InvalidConfig()` · `DeosxVault.sol:182` · Keeps `_totalRoom()` sum from overflowing and every tranche usable.

#### G-5
`if (!isWhitelisted[msg.sender]) revert NotWhitelisted(msg.sender)` · `DeosxVault.sol:209` · Off-chain KYC gate: only operator-approved wallets add capital.

#### G-6
`if (received < minimum && received != _totalRoom()) revert BelowMinimum(received, minimum)` · `DeosxVault.sol:214` · Limits position-list growth (gas bound, KNOWN_ISSUES §2) while letting the last room fill.

#### G-7
`if (pieces[i] < minPieces[i]) revert PlacementChanged(i, pieces[i], minPieces[i])` · `DeosxVault.sol:217` · Depositor slippage protection against a front-run that moves them into a lower-rate tranche.

#### G-8
`if (open != 0) revert RequestPending(open)` · `DeosxVault.sol:247` · One open request per wallet; makes every request's slice the wallet's oldest units (I-10, I-15).

#### G-9
`if (amount > free) revert ExceedsAvailable(free, amount)` · `DeosxVault.sol:250` · Reservation can never exceed capital held (I-9); also bounds `_snapshot`'s walk.

#### G-10
`if (r.owner != msg.sender) revert NotRequestOwner()` · `DeosxVault.sol:278` · Only the investor can release their own reservation.

#### G-11
`if (r.status != RequestStatus.Pending) revert NotPending()` · `DeosxVault.sol:279` · Cancel is a one-way Pending → Cancelled edge (I-11).

#### G-12
`if (to == address(0) || to == address(this)) revert InvalidRecipient(to)` · `DeosxVault.sol:317` · Stops `deployedCapital` from counting money that never left.

#### G-13
`if (cash < needed) revert InsufficientCapital(cash, needed)` · `DeosxVault.sol:643` · Capital outflows (`transferOut:319`, `fulfillWithdraw:353`) can never dip into interest pots.

#### G-14
`if (received > deployedCapital) revert ExceedsDeployed(deployedCapital, received)` · `DeosxVault.sol:331` · Keeps `deployedCapital` from underflowing / misreporting.

#### G-15
`if (r.status != RequestStatus.Pending) revert NotPending()` · `DeosxVault.sol:349` · Each request is paid at most once (I-11).

#### G-16
`if (r.feeStatus != FeeStatus.Due) revert FeeNotDue(requestId)` · `DeosxVault.sol:384` · Introducer fee paid at most once, only after the payout (I-12).

#### G-17
`if (pot < amount) revert InsufficientInterest(pot, amount)` · `DeosxVault.sol:636` · Interest/fees for a tranche can only come from that tranche's pot (I-4).

#### G-18
`if (allowed && _isInvestor(operator)) revert RoleConflict(operator)` · `DeosxVault.sol:405` · Staff/investor separation at operator appointment (I-14).

#### G-19
`if (topUp == 0 || opening < topUp) revert InvalidConfig()` · `DeosxVault.sol:413` · Same bound as G-3 on the only runtime writer of the minimums (I-13).

#### G-20
`if (allowed && (isOperator[wallet] || wallet == owner() || wallet == pendingOwner())) revert RoleConflict(wallet)` · `DeosxVault.sol:423` · Staff can never become depositors (I-14).

#### G-21
`if (introducer == address(this) || introducer == address(usdt) || _isLpToken(introducer)) revert InvalidRecipient(introducer)` · `DeosxVault.sol:435` · A fee must land somewhere that can spend it, and never back on the vault's capital side.

#### G-22
`if (_isInvestor(newOwner)) revert RoleConflict(newOwner)` · `DeosxVault.sol:458` · Staff/investor separation at ownership handover (I-14).

#### G-23
`if (left > 0) revert ExceedsCapacity(room)` · `DeosxVault.sol:588` · No partial fills; `taken ≤ size` (I-7).

#### G-24
`if (!isOperator[msg.sender] && msg.sender != owner()) revert NotOperator()` · `DeosxVault.sol:658` · Operator trust boundary for whitelist and introducer writes.

#### G-25
`if (msg.sender != vault) revert NotVault()` · `TrancheToken.sol:40` · LP supply moves only by vault mint/burn (X-1).

#### G-26
`if (from != address(0) && to != address(0)) revert SharesNonTransferable()` · `TrancheToken.sol:50` · LP balance stays bound to the depositor's positions (X-2).

---

## 2. Inferred Invariants (Single-Contract)

Inferred invariants are derived from structural analysis of the source code. Each block below cites one of five extraction methods in its `Derivation` field:

- **Δ-pair (delta-pair) analysis** — two or more storage variables in the same function body that change by equal-and-opposite amounts, implying a conservation law.
- **Guard lift** — a guard promoted to a global property by checking every write site of the constrained variable. Any unguarded write site makes it On-chain=**No**.
- **State-machine edge** — `require(state == A); state = B` with no reverse path.
- **Temporal predicate** — a check tied to `block.timestamp` or a stored duration.
- **NatSpec-stated global property** — a developer-asserted invariant in NatSpec or the spec.

---

#### I-1

`Conservation` · On-chain: **Yes**

> `Σ_i _tranches[i].capital == Σ_w capitalOf[w]` and `capitalOf[w] == Σ_i _capitalIn[w][i]`

**Derivation** — Δ-pair: `deposit` `DeosxVault.sol:224` (`_capitalIn += piece`) ↔ `:226` (`capital += piece`) ↔ `:228` (`capitalOf += received`, with `Σ pieces == received` from `_place:578-589`); `fulfillWithdraw` `:358` ↔ `:359` ↔ `:360` (all `-= amount`). No other writers.

**If violated** — per-wallet books and tranche capital diverge; `_isInvestor` and the opening-minimum switch read wrong values.

---

#### I-2

`Conservation` · On-chain: **Yes**

> `_tranches[i].capital == _lp[i].totalSupply()` for every tranche

**Derivation** — Δ-pair: `deposit` `DeosxVault.sol:226` ↔ `:234` (`_lp[i].mint(piece)`); `fulfillWithdraw` `:360` ↔ `:375` (`_lp[tranche].burn(amount)`). `TrancheToken.mint/burn` have no other caller (`TrancheToken.sol:40`). Fuzzed by `invariant_CapitalEqualsLpSupply`.

**If violated** — LP no longer represents 1 USDT of capital.

---

#### I-3

`Conservation` · On-chain: **Yes**

> `_capitalIn[w][i] == Σ_{j ≥ _head[w][i]} _positions[w][i][j].amount`, every entry from the head is non-zero

**Derivation** — Δ-pair: `deposit` `:223` (push `piece`) ↔ `:224` (`_capitalIn += piece`); `fulfillWithdraw` `:356` (`_consumeOldest` removes exactly `amount`, `:618-632`) ↔ `:358`. NatSpec `:617` — "Every position from the head on stays non-empty."

**If violated** — `_snapshot` (`:605`) could index past the array end or measure the wrong units.

---

#### I-4

`Conservation` · On-chain: **Yes**

> `totalInterestPot == Σ_i _tranches[i].interestPot`

**Derivation** — Δ-pair: `fundInterest` `:298` ↔ `:299`; `_spendInterest` `:637` ↔ `:638` (reached from `withdrawInterest:308`, `fulfillWithdraw:355`, `payIntroducerFee:385`). No other writers.

**If violated** — `_capitalCash` (`:648-651`) misclassifies pot money as capital, or the reverse.

---

#### I-5

`Conservation` · On-chain: **No**

> `usdt.balanceOf(vault) == Σ capital − deployedCapital + totalInterestPot`

**Derivation** — NatSpec (README "What the vault owes") — "`capitalCash + deployed = capitalOwed` as long as nothing arrives outside the vault's functions." Structural: there is no capital-side counter; `_capitalCash:648-651` derives it from `balanceOf`. Direct transfers, a Tether fee on outflows (`:312`, `:324`, `:376`, `:393` send gross amounts) or a seizure move the balance with no Δ in any of the three variables. Fuzzed (`invariant_UsdtAccountsExactly`) only under vault-routed flows with no fee.

**If violated** — `transferOut` / payouts see more or less capital cash than investors are owed (KNOWN_ISSUES §1).

---

#### I-6

`Bound` · On-chain: **Yes**

> `_tranches[0].taken` and `_tranches[1].taken` never decrease (T1/T2 never reopen)

**Derivation** — guard-lift: write sites of `taken` are `deposit:225` (`+=`) and `fulfillWithdraw:361` (`-=`, guarded by `tranche == REOPENING_TRANCHE`). No other writers.

**If violated** — a closed higher-rate tranche would reopen, contradicting the fund terms.

---

#### I-7

`Bound` · On-chain: **Yes**

> `_tranches[i].taken ≤ _tranches[i].size`

**Derivation** — guard-lift: `_place:584` caps each piece at `_room(i) = size − taken`, `:588` reverts on overflow; the only increment `deposit:225` adds that piece. `size` is written once in the constructor (`:183`).

**If violated** — `_room` underflows and every deposit and `previewDeposit` reverts.

---

#### I-8

`Ratio` · On-chain: **Yes**

> `_tranches[2].taken == _tranches[2].capital`

**Derivation** — Δ-pair: `deposit:225` ↔ `:226` (both `+= piece`); `fulfillWithdraw:360` ↔ `:361` (both `-= amount` when `tranche == 2`). NatSpec `:45` — "in T3 the capital still in it."

**If violated** — T3 room drifts from its actual capital (blocked or overfilled).

---

#### I-9

`Bound` · On-chain: **Yes**

> `reserved[w][t] ≤ _capitalIn[w][t]`, and at most one tranche per wallet has non-zero `reserved`

**Derivation** — guard-lift: `reserved` write sites are `requestWithdraw:254` (guarded by G-8 + G-9), `cancelWithdraw:281` (→0), `fulfillWithdraw:357` (→0). While reserved, `_capitalIn` only grows (`deposit:224`) or drops in the same call that zeroes `reserved` (`:357-358`). Fuzzed by `invariant_PendingMatchesReserved`.

**If violated** — `available()` (`:502`) underflows; a request could cover capital no longer held.

---

#### I-10

`StateMachine` · On-chain: **Yes**

> `openRequestOf[w] != 0` ⇔ `_requests[openRequestOf[w]]` is Pending and owned by `w`; `_pending` contains exactly these ids

**Derivation** — edge: `0@:247 → id@:269` (with `_pending.add:268`); `id → 0` at `cancelWithdraw:284` and `fulfillWithdraw:365`, each paired with `_pending.remove` (`:283`, `:364`) and a status change off Pending.

**If violated** — a wallet could hold two overlapping requests whose slices are not its oldest units.

---

#### I-11

`StateMachine` · On-chain: **Yes**

> `RequestStatus`: `None → Pending → {Cancelled | Paid}`; both terminal

**Derivation** — edge: `None→Pending@:262`; `Pending@:279 → Cancelled@:282`; `Pending@:349 → Paid@:362`. No writer sets Pending except a fresh id (`:256`).

**If violated** — double payout or a paid request being cancelled.

---

#### I-12

`StateMachine` · On-chain: **Yes**

> `FeeStatus`: `None → Due` (only at payout, only with an introducer) `→ Paid`; one-shot per request

**Derivation** — edge: `None→Due@:368` (inside `fulfillWithdraw`, `introducer != 0`); `Due@:384 → Paid@:386`. `_feesDue` add/remove paired at `:369` / `:388`.

**If violated** — introducer paid twice or before the investor.

---

#### I-13

`Bound` · On-chain: **Yes**

> `0 < topUpMinimum ≤ openingMinimum`

**Derivation** — guard-lift: write sites constructor `:190-191` (G-3) and `setMinimums:414-415` (G-19). No others.

**If violated** — zero-amount top-ups could flood position lists (KNOWN_ISSUES §2 gas bound).

---

#### I-14

`Bound` · On-chain: **Yes**

> No address is simultaneously staff (operator / owner / pending owner) and investor (whitelisted or `capitalOf ≠ 0`)

**Derivation** — guard-lift: `isOperator` writer `setOperator:406` gated by G-18; `isWhitelisted` writer `setWhitelisted:426` gated by G-20 (operator, owner, pendingOwner); `pendingOwner` writer `transferOwnership:459` gated by G-22; `capitalOf` grows only via `deposit:228`, which requires whitelist (G-5). Ownership accept (OZ `acceptOwnership`) promotes a pendingOwner that G-20 kept off the whitelist.

**If violated** — the Safe or an operator could pay itself (pre-audit finding fixed in `f9f7f50`).

---

#### I-15

`Temporal` · On-chain: **Yes**

> A pending request's split (`heldUnderHalf/heldHalf/heldFull`) is measured at `requestedAt` over the wallet's oldest `amount` units and never changes

**Derivation** — temporal: `_snapshot(msg.sender, tranche, amount, uint64(block.timestamp))` `:252-253`; the split fields are written only at `:265-267`. Covered units can only be removed by `_consumeOldest` in `fulfillWithdraw`; deposits push to the tail (`:223`). NatSpec `:242` — "That split is final: the request is paid on it." Fuzzed by `invariant_PendingSplitsNeverChange`.

**If violated** — the Safe would price interest from units the payout doesn't remove.

---

#### I-16

`Temporal` · On-chain: **Yes**

> `0 < halfTierAfter < fullTierAfter`, both immutable

**Derivation** — temporal: G-2 at `:178`; immutables assigned once at `:188-189`; used by `_tierBps:591-594`.

**If violated** — tiers would be non-monotone in holding time.

---

#### I-17

`Bound` · On-chain: **No**

> A request's recorded introducer is a third party (not the investor itself, an operator or the owner)

**Derivation** — guard-lift: the only `introducerOf` writer `setIntroducer:438` refuses vault/USDT/LP (G-21) but not `introducer == wallet` or staff; `requestWithdraw:263` copies it unchecked. (KNOWN_ISSUES §3.)

**If violated** — self-referral fees if the Safe signs without checking the portal records.

---

#### I-18

`Bound` · On-chain: **No**

> A fee marked Due is backed by money in its tranche's pot

**Derivation** — guard-lift: `FeeStatus.Due` set at `fulfillWithdraw:368` with no pot reservation; `interestPot` is debited only at `_spendInterest:636-638` when the fee is paid. Other payouts and `withdrawInterest` can drain the pot first. (KNOWN_ISSUES §5.)

**If violated** — `payIntroducerFee` reverts until the Safe re-funds.

---

#### I-19

`Bound` · On-chain: **No**

> Capital reserved by pending requests stays available as capital-side cash

**Derivation** — guard-lift: `transferOut:319` checks only `cash ≥ amount` (G-13), not `cash − Σ reserved`; payouts then hit G-13 at `:353`. (KNOWN_ISSUES §4.)

**If violated** — pending requests cannot be paid until the Safe calls `returnCapital`.

---

#### I-20

`Conservation` · On-chain: **Yes**

> Credited inflows equal the USDT that actually arrived

**Derivation** — Δ-pair: `_pull:550-552` measures `balanceOf` before/after; `deposit:211` (credits `received`), `fundInterest:297-298`, `returnCapital:330-332` all use that value.

**If violated** — a Tether transfer fee would over-credit capital or pots.

---

#### I-21

`Bound` · On-chain: **No**

> Outflows deliver exactly the amount debited from the books

**Derivation** — guard-lift: debits at `fulfillWithdraw:355-360`, `withdrawInterest:308`, `transferOut:320`, `payIntroducerFee:385` precede `safeTransfer` of the gross amount (`:376`, `:312`, `:324`, `:393`) with no received-amount check. Holds only while Tether's fee is 0 (spec §9).

**If violated** — recipients receive less than recorded; `deployedCapital` over-states what left.

---

## 3. Inferred Invariants (Cross-Contract)

Trust assumptions that span contract boundaries. Each block cites both caller-side and callee-side code.

---

#### X-1

On-chain: **Yes**

> LP supply changes only through `DeosxVault`'s own mint and burn calls

**Caller side** — `DeosxVault.sol:234`, `:375` — vault mints/burns 1:1 with `capital` (I-2).

**Callee side** — `TrancheToken.sol:31-37` gated by `_checkVault:40` against `vault = msg.sender` set once at `:18` (the vault constructor deploys it at `DeosxVault.sol:185`).

**If violated** — LP supply could be inflated without capital.

---

#### X-2

On-chain: **Yes**

> `lp[i].balanceOf(w) == _capitalIn[w][i]`, so `burn(investor, amount)` at payout never reverts for lack of balance

**Caller side** — `DeosxVault.sol:375` burns `r.amount` after `:358` reduces `_capitalIn` by the same amount; G-9 bounds `amount` by `_capitalIn`.

**Callee side** — `TrancheToken._update:49-52` blocks every non-mint/burn move; `approve:44-46` always reverts; mint/burn only by the vault (X-1).

**If violated** — a payout would revert or burn units belonging to someone else.

---

## 4. Economic Invariants

Higher-order properties derived from combinations of §2 and §3 invariants.

---

#### E-1

On-chain: **Yes**

> One LP unit is always redeemed for exactly one USDT of capital (interest is paid on top, outside the token)

**Follows from** — `I-2` + `I-3` + `X-1` + `X-2` (and `fulfillWithdraw:376` paying `amount + interest`)

**If violated** — LP would stop being a 1:1 capital receipt.

---

#### E-2

On-chain: **Yes**

> Interest and introducer fees can never be paid out of capital, and capital outflows can never touch interest pots

**Follows from** — `I-4` + G-13 / G-17 (`_capitalCash` excludes `totalInterestPot`; `_spendInterest` debits only the tranche's pot)

**If violated** — one tranche's interest could fund another tranche's payout or capital deployment.

---

#### E-3

On-chain: **No**

> Every outstanding LP unit can be redeemed on demand

**Follows from** — `I-5` (No) + `I-19` (No) + `I-21` (No): redemption depends on the Safe returning deployed capital, on no off-book balance changes, and on Tether's fee staying off.

**If violated** — investors wait on the Safe; there is no on-chain queue order or pro-rata rule (KNOWN_ISSUES §4).
