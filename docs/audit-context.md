# DEOS X Yield Fund vault: context for auditors

This document explains what the contracts are for, how money moves through them, who is trusted with what, and where we would most like your attention. It complements, and does not replace:

- [`README.md`](../README.md): integration guide (investor app, backend, Safe recipes, events, errors).
- [`docs/design-v2.md`](design-v2.md): the approved design and its decisions.
- [`KNOWN_ISSUES.md`](../KNOWN_ISSUES.md): accepted behaviour and the fixes made after our internal pre-audit scan.
- [`x-ray/`](../x-ray/x-ray.md): threat model, [entry points](../x-ray/entry-points.md), [invariant map](../x-ray/invariants.md).

---

## 1. Scope

| File | nSLOC | What it is |
| --- | ---: | --- |
| `src/DeosxVault.sol` | 482 | The vault: tranches, positions, withdrawal requests, interest pots, payouts, roles |
| `src/TrancheToken.sol` | 35 | Non-transferable LP receipt, one per tranche, deployed by the vault |
| **Total** | **517** | |

- **Out of scope:** `src/testnet/` (`TestTether`, `SepoliaFaucet`; Sepolia-only and never deployed on mainnet), `script/`, `test/`. `script/Deploy.s.sol` is worth reading for context, because it fixes the mainnet parameters.
- **Target chain:** Ethereum mainnet, with mainnet USDT `0xdAC17F958D2ee523a2206206994597C13D831ec7`.
- **Upgradeability:** none. There is no proxy, and the vault is deployed with `new`.
- **Toolchain:** Solidity 0.8.30, `evm_version = cancun`, optimizer on with 200 runs. Dependencies are OpenZeppelin Contracts v5.7.0 and forge-std v1.16.2, both unmodified submodules pinned in `foundry.lock`.
- **External dependencies:** USDT is the only one. There are no oracles, DEXes, lending markets, bridges or signatures.

## 2. What the product is

The **Stablecoin Yield Fund** is an off-chain, professionally managed fund that raises **USDT 20M** from a small set of vetted investors (KYC is done off-chain). Investors are onboarded through a web portal with Privy embedded wallets. The vault is the on-chain custody and bookkeeping layer for their capital.

- The raise is split into **three fixed tranches** that fill in order: **T1 2M → T2 3M → T3 15M**. Earlier tranches pay a higher fixed annual rate: **15% / 10% / 7%** for T1 / T2 / T3.
- An **introducer** (the person who brought the investor) earns **10% / 5% / 3%** a year on the capital they introduced, by tranche.
- The fund manager deploys the capital off-vault (to the fund's strategies or custodian) and brings it back to pay investors out.
- **None of the rates are on-chain.** The vault does no interest maths. It stores capital, a separate interest pot per tranche, and dated positions, so that the admin can work out and sign each interest and fee amount by hand. The rates and the interest formula live in the portal and its API. The off-chain calculator must round down.

On mainnet the admin is a **Safe multisig**. Every movement of money out of the vault is a Safe transaction.

## 3. Actors and trust

| Actor | How identified | Can do | Trust |
| --- | --- | --- | --- |
| **Owner (Safe)** | `owner()`; set in the constructor; two-step transfer; `renounceOwnership` reverts | All money movement (`fundInterest`, `withdrawInterest`, `transferOut`, `returnCapital`, `fulfillWithdraw`, `payIntroducerFee`), `setOperator`, `setMinimums`, `pause`/`unpause`, plus everything an operator can do | **Fully trusted.** No timelock, no caps. The Safe can send all capital-side USDT anywhere (`transferOut`), and investors are repaid only if it pays them. |
| **Operator** (portal backend key) | `isOperator[addr]`, appointed and removed by the Safe | `setWhitelisted`, `setIntroducer` only | **Bounded.** Cannot move funds. A compromised key can whitelist wallets and change the introducer recorded on future requests. |
| **Investor** | `isWhitelisted[wallet]` to deposit; any wallet with capital can exit | `deposit`, `requestWithdraw`, `cancelWithdraw` (own requests) | Untrusted. Only ever touches its own capital. |
| **Introducer** | `introducerOf[wallet]` | Nothing on-chain; only receives fees the Safe pays | Untrusted recipient. |
| **USDT (Tether)** | Immutable `usdt` | Can blacklist, pause, charge a fee, or seize | Trusted external dependency (see §8). |

**Staff and investors are kept apart.** The owner, the pending owner and operators cannot be whitelisted. A wallet that is whitelisted or still holds capital cannot be made an operator or the owner. The error is `RoleConflict`. Without this rule, an owner who was also an investor could pay their own request any interest they liked.

## 4. How it works

### 4.1 Money buckets

The vault holds a single USDT balance, logically split into two kinds of money:

```
usdt.balanceOf(vault) = capital-side cash + Σ interestPot[t]           (totalInterestPot)

capital-side cash  = balance − totalInterestPot  (read as 0 if balance < pots)
capital owed       = Σ tranche.capital = Σ LP supply
capital owed       = capital-side cash + deployedCapital   (holds while USDT moves only through vault functions)
```

- **Capital** is what investors deposited, 1:1 with LP. Part of it sits in the vault as capital-side cash; the rest is out with the fund manager, tracked by `deployedCapital`.
- **Interest pots**: one per tranche, pre-funded by the Safe. Interest and introducer fees for a tranche can only come from that tranche's pot. `transferOut` and capital payouts can never draw on any pot.
- There is **no counter for capital-side cash**: it is derived from `balanceOf`. USDT sent to the vault with a plain transfer therefore becomes Safe-spendable capital (accepted; `KNOWN_ISSUES.md` §1).

### 4.2 Deposit and the waterfall

```
investor ── usdt.approve(vault, amount) ──► USDT
investor ── deposit(amount, minPieces[3]) ──► DeosxVault          [nonReentrant, whenNotPaused]
   1. require isWhitelisted[msg.sender]
   2. received = balance delta of safeTransferFrom          (a Tether fee is never credited)
   3. minimum = capitalOf == 0 ? openingMinimum (100k) : topUpMinimum (10k)
      exempt if received == total room left (so the last room can always be filled)
   4. _place(received): fill T1 room, then T2, then T3; revert ExceedsCapacity if it doesn't fit
   5. pieces[i] >= minPieces[i]  else PlacementChanged         (slippage guard vs. a deposit mined first)
   6. per piece: push Position{amount, depositedAt=now}; _capitalIn += ; taken += ; capital +=
   7. capitalOf += received; emit Deposited
   8. TrancheToken[i].mint(investor, piece)                    (after all bookkeeping)
```

**Room rules.** For T1 and T2, `taken` counts every unit ever deposited and never goes down, so **T1 and T2 never reopen**. For T3, `taken` is the capital currently in T3, so **T3 reopens** when T3 capital is paid out, first come first served. One deposit can be split across tranches. For example, 5M into an empty fund becomes 2M in T1 and 3M in T2, as two positions.

### 4.3 Positions and holding tiers

Each deposit piece is a **position** `{amount, depositedAt}` in the wallet's per-tranche list, kept in deposit order. A head pointer `_head[wallet][tranche]` skips positions that have been fully paid out. Every position from the head onwards is non-empty.

The holding tier of a unit depends on how long it has been held:

| Held for | Tier (information only) |
| --- | --- |
| `< halfTierAfter` (60 days) | 0% |
| `≥ 60 days`, `< fullTierAfter` (90 days) | 50% |
| `≥ 90 days` | 100% |

The contract **reports** tiers and never enforces them. On Sepolia the clock is compressed, so a day becomes a minute.

### 4.4 Withdrawal request

```
investor ── requestWithdraw(tranche, amount) ──► DeosxVault       [whenNotPaused; no whitelist check]
   - at most ONE pending request per wallet across all tranches (openRequestOf) else RequestPending
   - 1 unit ≤ amount ≤ _capitalIn[wallet][tranche]  (no minimum)
   - _snapshot(): walk the wallet's OLDEST `amount` units from the head and split them into
       heldUnderHalf / heldHalf / heldFull as of now  → stored on the request (frozen)
   - reserved[wallet][tranche] = amount; request.introducer = introducerOf[wallet] (copied now)
   - emit WithdrawRequested(id, owner, tranche, amount, underHalf, half, full)
investor ── cancelWithdraw(id) ──► releases the reservation (works while paused)
```

LP stays with the investor until payout. New deposits only append positions at the tail, so the units a pending request covers, which are the oldest ones, cannot change. That is why the frozen split stays valid.

### 4.5 Payout (Safe)

```
Safe ── fulfillWithdraw(id, interest) ──► DeosxVault                [onlyOwner, nonReentrant]
   1. request must be Pending
   2. capital-side cash ≥ amount             else InsufficientCapital (Safe must returnCapital first)
   3. interestPot[tranche] ≥ interest         else InsufficientInterest; pot -= interest
   4. _consumeOldest(): remove exactly the oldest `amount` units (advance head, trim the next one in place)
   5. books: reserved=0, _capitalIn -= , capitalOf -= , capital -= , (T3 only) taken -=
   6. status = Paid; if request.introducer != 0 → feeStatus = Due (emit IntroducerFeeDue)
   7. TrancheToken.burn(investor, amount); usdt.safeTransfer(investor, amount + interest)
```

The Safe picks `interest` off-chain from the request's frozen split and the fund's terms. The contract only checks that the pot can cover it.

### 4.6 Introducer fee (Safe)

```
Safe ── payIntroducerFee(id, fee) ──► DeosxVault                    [onlyOwner, nonReentrant]
   - only when feeStatus == Due; once per request; fee may be 0 (closes it)
   - fee comes from the same tranche's interest pot; paid to the introducer recorded on the request
```

### 4.7 Capital deployment and pots (Safe)

| Function | Effect |
| --- | --- |
| `fundInterest(t, x)` | Pull USDT; `interestPot[t] += received`; `totalInterestPot += received` |
| `withdrawInterest(t, x)` | `interestPot[t] -= x`; send to the Safe |
| `transferOut(to, x)` | `x ≤ capital-side cash`; `deployedCapital += x`; send to `to` (any address except 0 and the vault) |
| `returnCapital(x)` | Pull USDT; `deployedCapital -= received` (at most what is out) |

### 4.8 State machines

```
Request.status:     None ──request──► Pending ──cancel──► Cancelled
                                        └──fulfill──► Paid
Request.feeStatus:  None ──fulfill (introducer≠0)──► Due ──payIntroducerFee──► Paid
Tranche room:       T1/T2 taken only increases; T3 taken == T3 capital
```

`pause()` blocks only `deposit` and `requestWithdraw`. Cancelling and every Safe action keep working while paused, so a pause can never trap a request.

## 5. TrancheToken (dxT1 / dxT2 / dxT3)

- `TrancheToken` is a standard OpenZeppelin `ERC20` with the same decimals as USDT (6). The vault is `msg.sender` at construction and is the only address allowed to `mint` and `burn`.
- It is **non-transferable**. `_update` reverts unless the call is a mint or a burn, and `approve` always reverts. `transferFrom` fails on allowance first, because no allowance can ever exist.
- 1 LP always equals 1 USDT of capital in that tranche. Interest is paid on top and is never reflected in the token.
- Per tranche, `LP.totalSupply == tranche.capital == Σ wallets' _capitalIn == Σ open positions`.

## 6. Invariants we rely on

The Foundry invariant suite (`test/DeosxVault.invariant.t.sol`) checks 12 invariants. It uses a 16-action handler, runs 256 runs × depth 100, and sets `fail_on_revert = true`.

| # | Invariant |
| --- | --- |
| 1 | `CapitalEqualsLpSupply`: per tranche, capital == LP supply ≤ size; room == size − taken; T1/T2 capital ≤ taken; T3 capital == taken |
| 2 | `UsdtAccountsExactly`: balance == capital-side cash + pots; cash + deployed == capital owed + direct transfers; balance == all inflows − all outflows |
| 3 | `StaffAndInvestorsApart`: no investor (whitelisted or holding capital) is an operator, the owner or the pending owner; the owner is never whitelisted |
| 4 | `MinimumsOrdered`: `0 < topUpMinimum ≤ openingMinimum` |
| 5 | `PotsSumToTotal`: Σ `interestPot[t]` == `totalInterestPot` == funded − interest paid − fees paid − withdrawn |
| 6 | `PerInvestorBooks`: per wallet and tranche, Σ open positions == LP balance == available + reserved; `capitalOf` == Σ LP across tranches |
| 7 | `EachPotMatchesItsOwnFlows`: each pot == funded − interest − fees − withdrawn **for that tranche only** |
| 8 | `PendingMatchesReserved`: per wallet and tranche, Σ pending request amounts == `reserved` |
| 9 | `OneOpenRequestPerWallet`: `openRequestOf[w]` names the wallet's only pending request, whose amount is all reserved in its tranche; 0 ⇒ none pending, nothing reserved |
| 10 | `PendingSplitsAddUp`: a pending request's split sums to its amount and equals the tiers of the wallet's oldest units at `requestedAt` |
| 11 | `PendingSplitsNeverChange`: a pending request's split never changes after it is made |
| 12 | `WaterfallOrder`: T2 has taken capital ⇒ T1 is full; T3 has taken capital ⇒ T2 is full |

The full catalogue of guards and inferred invariants is in [`x-ray/invariants.md`](../x-ray/invariants.md). Its On-chain=No items all correspond to entries in `KNOWN_ISSUES.md`.

## 7. Deliberate design choices (please do not report these as missing features)

- **The admin prices all interest.** The contract does no interest or NAV maths and cannot check the `interest` or `fee` it is given; it only checks that the pot covers them.
- **Interest is paid only when capital is withdrawn.** There is no on-chain periodic coupon, no lock-up, and no automatic 90-day cycle. The 60/90-day tiers are reported, not enforced.
- **The Safe is the custodian.** `transferOut` has no cap, no reserve floor and no timelock. Investors are repaid only if the Safe brings capital back. There is no on-chain queue or pro-rata rule when cash is short, and there is no loss accounting.
- **Investors cannot force their own exit.** There is no admin-initiated redemption, no wind-down function, and no recovery of a lost investor wallet; LP is non-transferable.
- **One pending request per wallet**, with no request minimum.
- **Not upgradeable**, so fixes need a new deployment and a migration.

The full list, with impact and operating rules, is in [`KNOWN_ISSUES.md`](../KNOWN_ISSUES.md).

## 8. USDT behaviour we assume

| USDT trait | How the vault handles it |
| --- | --- |
| No return value on `transfer`/`transferFrom`/`approve` | `SafeERC20` everywhere |
| `approve` from non-zero to non-zero reverts | The vault never approves. Users and the Safe approve exact amounts and reset to 0 first if needed. |
| Transfer fee switch (0 today) | Inflows (`deposit`, `fundInterest`, `returnCapital`) credit the measured balance delta. Outflows would deliver less than recorded (accepted). |
| Blacklist | Mainnet USDT checks only the **sender**, so a blacklisted investor or introducer can still be paid (fork test). A blacklisted **vault** freezes everything. |
| Pause / seizure / `destroyBlackFunds` | Out of our control. Capital-side cash reads 0 rather than underflowing if the balance drops below the pots. |
| 6 decimals | LP decimals mirror `usdt.decimals()`; the deploy script requires 6 |

## 9. Where we would like your focus

1. **The position queue.** `_snapshot` (`DeosxVault.sol:598`) and `_consumeOldest` (`:618`), together with the `_head` pointer, must remove exactly the units that were snapshotted, including partial heads, positions split at a tranche boundary, deposits made while a request is pending, and cancel-then-re-request. Gas grows with the number of positions (KNOWN_ISSUES §2).
2. **Capital/interest separation.** `_capitalCash` (`:648`), `_requireCapital`, and the order of checks and transfers in `fulfillWithdraw` (`:346`), `transferOut` (`:316`) and `payIntroducerFee` (`:382`). Can capital ever be paid from a pot, or a pot be drained by a capital path?
3. **Request and reservation lifecycle.** One open request per wallet across tranches (`:243`), `reserved` and `openRequestOf` being cleared on both cancel and payout, and interaction with pause.
4. **Deposit waterfall.** `_place` (`:578`), the `minPieces` guard, the exact-room minimum exemption (`:214`), and T3 reopening on payout.
5. **Role separation and ownership.** `_isInvestor` (`:566`), `setOperator`, `setWhitelisted`, and the `transferOwnership` override with the pending-owner window.
6. **TrancheToken.** Confirm that no inherited ERC20 path (zero-value `transferFrom`, `transfer` to self, and so on) can move LP.

## 10. Deployment and parameters

`script/Deploy.s.sol` deploys only to chain 1 or chain 11155111. On mainnet any override reverts (`MainnetSettingsAreFixed`). The script also requires the Safe address to have code and USDT to have 6 decimals.

| Parameter | Mainnet | Sepolia | Mutable? |
| --- | --- | --- | --- |
| USDT | `0xdAC1…1ec7` | team `TestTether` | No (immutable) |
| Tranche sizes | 2M / 3M / 15M | same | No |
| `halfTierAfter` / `fullTierAfter` | 60 days / 90 days | 60 min / 90 min | No (immutable) |
| `openingMinimum` / `topUpMinimum` | 100,000 / 10,000 USDT | same | Safe (`setMinimums`, `0 < topUp ≤ opening`) |
| Owner | Safe multisig | Safe `0xf6ae…5dE5` | Two-step transfer |

Mainnet is not deployed yet. The Sepolia vault `0x92044EeE09Bc53F8D254bde733283e5255352a46` was deployed before the 5 October fixes. It still has `deposit(uint256)` and does not match the audited source; we will redeploy from the audit commit.

## 11. Running the tests

```bash
git submodule update --init --recursive
forge build
forge test                       # 151 pass, 2 fork tests skip without an RPC
SEPOLIA_RPC_URL=… forge test --match-contract Sepolia
MAINNET_RPC_URL=… forge test --match-contract Mainnet   # blacklisted payee is still paid
forge coverage --report summary  # DeosxVault 100% lines / 96% branches; TrancheToken 100%
```

| Suite | Covers |
| --- | --- |
| `DeosxVault.config.t.sol` | Constructor bounds, roles, minimums, ownership, pause |
| `DeosxVault.deposit.t.sol` | Waterfall, minimums, fee-on pulls, whitelist, LP non-transferability, waterfall fuzz |
| `DeosxVault.withdraw.t.sol` | Requests, splits at tier boundaries, cancel, payouts, T1/T2/T3 reopening rules, introducer fees, request/fulfill and random-ops fuzz |
| `DeosxVault.pots.t.sol` | Interest pots, `transferOut`/`returnCapital`, `vaultState` |
| `DeosxVault.auditFixes.t.sol` | Tests for each of the 6 fixes from the internal pre-audit (slippage guard, exact-room exemption, role conflicts, …) |
| `DeosxVault.gas.t.sol` | Gas per position for request and payout (KNOWN_ISSUES §2) |
| `DeosxVault.invariant.t.sol` | The 12 invariants above |
| `DeosxVault.fork.t.sol` | Live Sepolia and mainnet USDT behaviour |

`test/mocks/MockTether.sol` reproduces USDT's quirks: no return value, the zero-first approve rule, the fee switch and the blacklist.

## 12. Prior review

The code has had one AI-assisted review only: an x-ray report followed by a 5-pass automated audit scan, with the 6 findings fixed on 5 October 2026 (`KNOWN_ISSUES.md`, "Fixed after the pre-audit scan"). Slither and Aderyn report no issues beyond false positives and the centralization noted above. **This is the first external audit.**
