# DEOS-X tranche vault v2: design

Date: 1 Oct 2026 · Status: approved; deployed to Sepolia on 1 Oct 2026; mainnet after the external audit · Chains: Ethereum Sepolia (rehearsal), then Ethereum mainnet · Scope: smart contracts only

Supersedes the v1 design (`2026-09-30-deosx-tranche-vault-design.md`, kept in the product repo). v1 calculated interest on-chain (yield periods, checkpointed indexes, per-investor NAV, introducer fees by formula, 90-day auto-renewing cycles). v2 drops all of that: the contract holds capital and interest in separate pots per tranche, and the admin decides every interest and introducer amount by hand. v1 is deployed on Sepolia at `0x261CF2ED518B61DD5fa94217b536939bf566d5BD`; v2 replaces it with a fresh deployment: vault `0x92044EeE09Bc53F8D254bde733283e5255352a46`, `TestTether` `0xAC33F56E6EE2dA84ECB66253A3917c0132A8ce06`, owned by the Safe `0xf6ae15BB022886832814F3980303A0d9e65E5dE5`.

## 1. What this is

The on-chain vault of the Stablecoin Yield Fund, for real investors' USDT on Ethereum mainnet, rehearsed on Sepolia first and audited before mainnet.

1. Investors deposit USDT from the app. Each deposit is placed into three tranches in order and mints that tranche's LP token 1:1.
2. Each tranche has a **capital pot** (what investors deposited, equal to its LP supply) and an **interest pot** (what the admin has pre-funded for that tranche's interest and introducer fees).
3. An investor asks to withdraw some or all of their LP in a tranche. The admin, a Safe multisig, sees the request with how long each part of the position has been held, decides the interest by hand, and pays: the LP is burned, the capital comes back 1:1, the interest comes from that tranche's interest pot.
4. When an introduced investor's withdrawal is paid, the contract flags the introducer fee as due; the admin pays an amount of their choosing from the same tranche's interest pot.

The contract calculates no interest. It records positions, holding periods and eligibility so the admin can decide, and it keeps capital and interest money apart.

### Success criteria

- Deposits are placed exactly by the tranche rules in section 4.
- Withdrawals of any part of a position return exactly the LP burned in USDT, plus the interest the admin keyed in.
- Interest and introducer fees can only come from the right tranche's interest pot, and capital sent out can never touch an interest pot.
- The admin can see, for every request, how much of it was held under 60 days, 60 to 89 days, and 90 days or more.

### Out of scope

- Any interest, NAV or compounding calculation on-chain. The 0% / 50% / 100% tiers are shown to the admin, not enforced.
- Front-running protection, KYC on-chain (the app's whitelist stands in), upgradeability, losses.

## 2. Chains and settings

| Setting | Ethereum Sepolia (11155111) | Ethereum mainnet (1) | Changeable |
| --- | --- | --- | --- |
| USDT | the team's `TestTether` `0xAC33F56E6EE2dA84ECB66253A3917c0132A8ce06` (address given to the deploy script) | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | no |
| Tranche sizes (T1 / T2 / T3) | 2,000,000 / 3,000,000 / 15,000,000 | same | no |
| `halfTierAfter` (50% eligibility from) | 60 minutes | 60 days | no |
| `fullTierAfter` (100% eligibility from) | 90 minutes | 90 days | no |
| Opening / top-up minimum | 100,000 / 10,000 | same | Safe (`setMinimums`, and the constructor: top-up above 0 and at most the opening minimum) |

Sepolia compresses the clock (one day = one minute) and keeps mainnet's dollar amounts. Sepolia's Test Tether USD (`0x7169D38820dfd117C3FA1f22a697dBA58d90BA06`) can no longer mint: on 1 Oct 2026 its total supply stood at the uint256 maximum, so `_giveMeATokens`, and the `TestUsdtFaucet` built on it, always revert. The rehearsal uses the team's own `TestTether` instead, and the faucet is retired. Tranche interest rates live in the portal (`lib/fund.ts`), not in the contract.

## 3. Contracts

| Contract | Change |
| --- | --- |
| `DeosxVault` | Rewritten as below. |
| `TrancheToken` | Unchanged: `dxT1` / `dxT2` / `dxT3`, decimals equal to USDT's, minted and burned only by the vault, never transferable. |
| `TestUsdtFaucet` | Removed: the token under it can no longer mint. |
| `TestTether` (new, Sepolia only) | USDT's behaviour where the vault and the app meet it (6 decimals, `transfer` / `transferFrom` / `approve` return nothing, `approve` rejects changing one non-zero allowance to another), and an open `mint` of up to 20,000,000 per call, so the supply can't realistically be pushed to the uint256 limit. |

Solidity 0.8.30, OpenZeppelin v5.7.0 (`Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeERC20`, `EnumerableSet`). Not upgradeable.

## 4. Roles, deposits and tranches

### Roles (unchanged from v1)

| Who | Can |
| --- | --- |
| Owner: the Safe (`Ownable2Step`; `renounceOwnership` reverts) | Everything in section 8, plus what an operator can do. |
| Operators (any number; appointed and removed only by the Safe) | `setWhitelisted(wallet, bool)`, `setIntroducer(wallet, introducer)` (never the vault itself: `InvalidRecipient`). |
| Whitelisted wallets | `deposit`. |
| Any wallet holding LP | `requestWithdraw`, `cancelWithdraw` on its own requests; no whitelist check, so a removed wallet can still leave. |

### Tranche room

- **T1 and T2 never reopen.** Their room is `size − taken`, where `taken` is all capital ever placed in them and never goes down.
- **T3 reopens.** Its room is `size − capital currently in T3`. When T3 capital is paid out, that room is free again, first come, first served.
- The total the fund can hold at once is therefore capped, and once T1 and T2 have been filled every new deposit can only go to T3.

### `deposit(amount)`

Reverts while paused. In order:

1. `NotWhitelisted(sender)` unless whitelisted.
2. `ZeroAmount` for 0. Pull `amount` and measure `received` (balance after minus before), so a Tether fee can't be credited.
3. `BelowMinimum(received, minimum)`: the opening minimum when the wallet holds no capital in any tranche, the top-up minimum otherwise.
4. Place `received` into T1's room, then T2's, then T3's. `ExceedsCapacity(room)` if it doesn't all fit; nothing is partly filled.
5. For each tranche that received a piece: add a **position** `{amount, depositedAt = now}` to the wallet's list for that tranche; add to the tranche's capital and `taken`; after all bookkeeping, mint that tranche's LP to the wallet 1:1. (In T3, `taken` is its current capital: a payout from T3 lowers it again.)
6. Emit `Deposited(wallet, received, perTranche[3])`.

`previewDeposit(amount)` returns the split a deposit of `amount` would get now.

## 5. The two pots and the capital sent out

Per tranche the vault keeps `capital` (equal to the tranche's LP supply) and `interestPot`.

| Function (Safe) | Effect |
| --- | --- |
| `fundInterest(tranche, amount)` | Pulls USDT from the Safe; `interestPot[tranche] += received`. |
| `withdrawInterest(tranche, amount)` | Sends unused interest back to the Safe; `InsufficientInterest(available, needed)` if the pot holds less. |
| `transferOut(to, amount)` | Sends **capital-side** USDT anywhere; `deployedCapital += amount`. `InsufficientCapital(available, needed)` if `amount` exceeds the vault's balance minus the sum of all interest pots (taken as 0 if the balance is ever below the pots), so interest money never leaves this way. |
| `returnCapital(amount)` | Pulls USDT from the Safe; `deployedCapital −= received` (`ExceedsDeployed` if more than is out). |

The vault's USDT balance is always the capital-side cash plus the sum of the interest pots. USDT sent to the vault by plain transfer lands on the capital side, untracked.

## 6. Withdrawals

### Positions and eligibility

Each wallet has, per tranche, a list of positions in deposit order. A wallet has **at most one pending request at a time, across all tranches**; it claims the wallet's **oldest units** in its tranche, and its payout removes exactly those. A position's eligibility is set by how long it has been held:

| Held for | Tier |
| --- | --- |
| under `halfTierAfter` (60 days) | 0% |
| from 60 days, under `fullTierAfter` (90 days) | 50% |
| 90 days or more | 100% |

The tier is information for the admin; the contract enforces nothing with it.

### `requestWithdraw(tranche, amount) → requestId`

Reverts while paused. `ZeroAmount` for 0; `RequestPending(requestId)` if the wallet already has a pending request, in any tranche (shown to the user as "you already have a withdrawal request waiting; cancel it or wait for it to be paid"); `ExceedsAvailable(available, amount)` if `amount` is more than the wallet's LP in that tranche. Any amount from 1 unit up to that is allowed: there is no request minimum. One request per wallet keeps `pendingRequests()` no longer than the number of investors, and means a request's units are always the wallet's oldest in that tranche. Records a request:

- owner, tranche, `amount`, `requestedAt = now`;
- the wallet's introducer at this moment (zero for none);
- an eligibility split of the wallet's oldest `amount` units in that tranche: how much has been held under 60 days, 60 to 89 days, and 90 days or more, measured at `requestedAt`. Nothing can change those units while the request is pending, so the split is final and is the one the request is paid on.

The LP stays with the wallet but is reserved (`reserved(wallet, tranche)` is the request's amount). `openRequestOf(wallet)` is set to the request id. Emits `WithdrawRequested(requestId, owner, tranche, amount, heldUnderHalf, heldHalf, heldFull)`.

`cancelWithdraw(requestId)` (owner of the request, allowed while paused) releases the reservation and clears `openRequestOf(wallet)`, so the wallet can request again. A cancelled request keeps the split it was made with.

### `fulfillWithdraw(requestId, interest)` (Safe)

1. `UnknownRequest`, `NotPending` as applicable.
2. `InsufficientCapital(available, amount)` if the capital-side cash is short; `InsufficientInterest(pot, interest)` if the tranche's interest pot is short.
3. Effects first: burn bookkeeping (consume the wallet's oldest `amount` units in the tranche, the ones the split was measured on; reduce the tranche's capital; release the reservation and clear `openRequestOf(wallet)`), `interestPot[tranche] −= interest`, mark the request paid with `interest` (it keeps its split, measured at `requestedAt`), and if the request recorded an introducer (the wallet's introducer when the request was made) mark its fee **due**.
4. Burn `amount` LP from the owner; transfer `amount + interest` USDT to the owner.
5. Emit `WithdrawFulfilled(requestId, owner, tranche, amount, interest)` and, when an introducer is set, `IntroducerFeeDue(requestId, introducer)`: the admin's prompt.

`interest` may be 0. The admin decides it from the request's split (from the event or `getRequest`; fixed at the request) and the investor's position; the contract does not check it against the tier. `positionsOf` tiers are measured now, not at `requestedAt`, so they are not the basis for interest. If Tether ever turns on its transfer fee, the investor receives `amount + interest` less it.

### `payIntroducerFee(requestId, amount)` (Safe)

Only for a paid request whose fee is due; once per request (`FeeNotDue` otherwise). Takes `amount` (0 allowed, which simply closes the prompt) from that request's tranche interest pot and sends it to the introducer recorded on the request, even if the wallet's introducer has changed since; with a Tether fee on, the introducer receives `amount` less it. Emits `IntroducerFeePaid(requestId, introducer, amount)`.

## 7. Views

| View | Returns |
| --- | --- |
| `trancheInfo(i)` | Size, `taken`, room, capital, interest pot, LP token address. |
| `positionsOf(wallet, tranche)` | Open positions oldest first: amount left, `depositedAt`, seconds held, tier now (a request's split is measured at its `requestedAt` instead). |
| `available(wallet, tranche)` | LP not reserved by the wallet's pending request. |
| `reserved(wallet, tranche)` | The wallet's pending request's amount if it is in that tranche, else 0. |
| `openRequestOf(wallet)` | The wallet's pending request id across all tranches; 0 if none. |
| `getRequest(id)` | The request record, its split (fixed at the request), status, interest paid, introducer and fee state. |
| `pendingRequests()` | Request ids awaiting payout (at most one per investor; the admin UI indexes the request events and uses this to confirm). |
| `feesDue()` | Request ids whose introducer fee is due and unpaid. |
| `vaultState()` | USDT in the vault, capital owed (sum of tranche capital), sum of interest pots, capital-side cash (0 if the balance is ever below the pots), `deployedCapital`. |
| `previewDeposit(amount)` | Placement per tranche. |
| `isWhitelisted`, `introducerOf`, `isOperator`, minimums, thresholds, `usdt` | Public state. |

## 8. Admin summary

Safe only: `fundInterest`, `withdrawInterest`, `transferOut`, `returnCapital`, `fulfillWithdraw`, `payIntroducerFee`, `setOperator`, `setMinimums` (`InvalidConfig` unless 0 < top-up ≤ opening, the same check the constructor makes), `pause`, `unpause`, two-step ownership. Paused blocks only `deposit` and `requestWithdraw`. Every function that moves USDT is `nonReentrant` (listed first) and writes its bookkeeping before any external call.

## 9. Real USDT

As v1: `SafeERC20` everywhere; pulls credit what arrives; the zero-first `approve` rule is the app's and the Safe's concern; a blacklisted vault freezes everything; a blacklisted investor can still be paid.

## 10. Deployment

`script/Deploy.s.sol` as v1, with the settings of section 2 (USDT, the two thresholds, the minimums), mainnet and Sepolia only, the mainnet settings fixed, the Safe-has-code and 6-decimals checks, and the settings printed before broadcasting. Order: build and test → Sepolia deploy with the existing Safe and operators re-appointed → frontend switches to the new address and ABI → external audit → mainnet.

## 11. Testing

- **Unit:** waterfall and room rules (T1/T2 closed for good, T3 reopening after a payout and taking the next deposit), minimums (deposits, `setMinimums` bounds), whitelist and roles, one open request per wallet (`RequestPending` in the same and another tranche, a new request after cancel or payout, `openRequestOf` set and cleared, a 1-unit request), partial withdrawals consuming the oldest units, eligibility splits at the 60- and 90-day boundaries and across several positions, the paid split measured at `requestedAt`, cancel, pots (`fundInterest`, `withdrawInterest`, interest and fees from the T1, T2 and T3 pots only, `transferOut` unable to touch interest), fee due and paid once to the introducer recorded on the request, fee-switch pulls, pause; a random-operations fuzz of one wallet's requests, splits and positions against a model.
- **Invariants:** per tranche, LP supply = capital = the sum of open positions; T1/T2 `taken` never decreases; USDT balance = capital-side cash + sum of interest pots; each tranche's pot is exactly what was funded into it less the interest and fees paid from it and what was taken back; every wallet with `openRequestOf` set has exactly that request pending and its reserves across tranches sum to that request's amount (0 with none); a pending request's split is its wallet's oldest units at its `requestedAt` and never changes; every payout reaches the right wallet in the right amount.
- **Fork tests** against live Sepolia and mainnet USDT (on mainnet a blacklisted investor and introducer are still paid); deploy-script tests.

## 12. Decisions

| Decision | Source |
| --- | --- |
| No interest calculation on-chain; the admin keys in interest and fees | User, 1 Oct |
| A capital pot (LP 1:1) and an interest pot per tranche; interest and fees only from that tranche's pot | User, 1 Oct |
| Eligibility tiers 0% / 50% / 100% at 60 and 90 days, shown not enforced | User, 1 Oct |
| Partial withdrawals; a payout removes the wallet's oldest units in the tranche | User and design, 1 Oct |
| T1 and T2 never reopen; T3 reopens first come, first served | User, 1 Oct |
| Investor requests, the Safe pays | User, 1 Oct |
| Introducer fee flagged at payout, paid by the admin afterwards from the pot, once | User, 1 Oct |
| Interest pots pre-funded and withdrawable by the Safe; `transferOut` limited to capital | Design, approved 1 Oct |
| No withdrawal minimum (any amount from 1 unit up to what is free); each investor has at most one pending request at a time across all tranches (`RequestPending(id)` otherwise, `openRequestOf(wallet)` to read it), which bounds `pendingRequests()` by the number of investors and makes every request's slice the wallet's oldest units, so its split is fixed at the request; no paginated views | User, 1 Oct (replaces the request minimum) |
| `setMinimums` and the constructor need 0 < top-up ≤ opening; `setIntroducer` refuses the vault; capital-side cash reads 0 rather than panicking if the balance is below the pots | Final review, 1 Oct |
