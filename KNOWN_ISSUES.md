# Known issues and accepted behaviour

Scope: `src/DeosxVault.sol`, `src/TrancheToken.sol`. Design: [`docs/design-v2.md`](docs/design-v2.md).

The items below are known to the team and are either accepted by design or covered by an operating rule. Please report them only if you find an impact beyond what is described here.

## Fixed after the pre-audit scan (5 Oct 2026)

An AI pre-audit (x-ray, then a 5-pass solidity-auditor scan) raised these; each is fixed and has a test in `test/DeosxVault.auditFixes.t.sol`:

| Issue | Fix |
| --- | --- |
| `setOperator` and `transferOwnership` checked only the whitelist flag, so a wallet taken off the whitelist that still held capital could become an operator or the owner (and, as owner, pay its own request with any interest). | Both now refuse any wallet that is whitelisted **or** has `capitalOf != 0` (`RoleConflict`). |
| `deposit(amount)` took no expected split, so a deposit mined first could push a depositor from T1 into a lower-rate tranche with no revert. | `deposit(amount, minPieces)`: reverts with `PlacementChanged` unless every tranche gets at least what the caller accepted (the app passes `previewDeposit`). |
| Room smaller than the minimum could never be filled. | A deposit of exactly all the room left is exempt from the minimum. |
| `setIntroducer` accepted USDT or an LP token, which could never spend a fee paid to it. | Both are refused (`InvalidRecipient`). |
| LP `approve` succeeded although the token can never be transferred. | `TrancheToken.approve` reverts with `SharesNonTransferable`. |
| Tranche sizes near `uint256` max would overflow the room sum and block every deposit. | The constructor refuses a size above `type(uint128).max`. |

## 1. USDT sent to the vault directly becomes capital the Safe can spend

**Behaviour.** The vault does not keep a counter of capital-side cash. It computes it as `usdt.balanceOf(vault) − totalInterestPot` (`_capitalCash`). USDT sent with a plain transfer, instead of `deposit`, `fundInterest` or `returnCapital`, mints no LP and is not recorded, but it raises capital-side cash, and the Safe can send it out with `transferOut` (which adds it to `deployedCapital`). A balance change outside the vault's functions (Tether seizing or burning vault funds, or a Tether transfer fee) also shifts capital-side cash with no record. If the balance falls below the pots, capital-side cash reads 0 instead of reverting.

**Status.** Accepted. Money sent outside the vault's functions belongs to the fund and is the Safe's to manage. `capitalCash + deployedCapital == Σ tranche capital` holds only while USDT moves through the vault's own functions.

## 2. Withdrawal gas grows with the number of positions a request covers

**Behaviour.** Every deposit piece is a separate position. `requestWithdraw` (`_snapshot`) and `fulfillWithdraw` (`_consumeOldest`) walk the wallet's positions in the tranche, oldest first, until the amount is covered. A deposit split at a tranche boundary and a partly paid position can leave entries smaller than the top-up minimum.

**Measured** (`test/DeosxVault.gas.t.sol`, each call its own transaction, gas before refunds, against the 16,777,216 per-transaction cap of EIP-7825):

| | Gas per position covered | Most positions in one transaction |
| --- | ---: | ---: |
| `requestWithdraw` | ~5,180 | ~3,180 |
| `fulfillWithdraw` | ~5,600 | ~2,940 |

**Worst case under the current minimums** (100,000 opening, 10,000 top-up): a wallet that already holds capital in T1 or T2 needs no opening deposit in T3, so all 15,000,000 of T3 can be 10,000 top-ups (1,500 positions), plus one boundary piece and one partly paid head: about **1,502 positions**, roughly 8.0M gas to request and 8.6M to pay in full. Both fit.

**Status.** Accepted, with an operating rule. If `topUpMinimum` were lowered far enough, a full request or payout would no longer fit; the test shows 3,300 positions needing ~17M gas for one request. The wallet is never stuck: a request for part of the capital walks only the positions it covers (the test pays the oldest 1,000 positions in ~5.9M gas). **Operating rule: keep `topUpMinimum` at or above 5,500 USDT** (15,000,000 ÷ 5,500 + 2 ≈ 2,729 positions, under the ~2,940 payout limit with margin). Only the wallet that builds the positions bears the cost.

## 3. A wallet can be recorded as its own introducer, or a staff address

**Behaviour.** `setIntroducer(wallet, introducer)` refuses a zero wallet, the vault, USDT and the LP tokens. It does not refuse `introducer == wallet`, an operator or the owner. A request copies the wallet's introducer when it is made, and `payIntroducerFee` pays that recorded address, even if `introducerOf` changes later. An operator who changes the introducer just before a request moves that request's fee; an investor who requests before the backend's `setIntroducer` lands leaves the introducer with no fee recorded.

**Status.** Known, not fixed in this version. Only an operator (the portal backend) or the Safe can call `setIntroducer`, and the backend is responsible for refusing self-referral. Fees move only when the Safe signs `payIntroducerFee`, after checking `getRequest(id).introducer` against the portal's records (`README.md`, Admin UI recipes). A compromised operator key is removed with `setOperator(key, false)`.

## 4. Investors are repaid only if the Safe brings deployed capital back

**Behaviour.** `transferOut(to, amount)` sends capital-side USDT anywhere, with no cap, no reserve floor and no timelock; it does not set aside the capital that pending requests have reserved. `fulfillWithdraw` pays capital only from capital-side cash, so when enough capital is out, payouts revert `InsufficientCapital` until the Safe calls `returnCapital`. When cash is short, the Safe chooses which pending requests to pay: there is no on-chain queue order or pro-rata share. There is no function to record a loss on deployed capital; the spec puts losses out of scope.

**Status.** By design: this is the fund's mechanism and trust model. Interest pots are never at risk this way (`totalInterestPot` is excluded from capital-side cash).

## 5. Smaller accepted behaviours

| Behaviour | Why it stays |
| --- | --- |
| **Tether's blacklist does not block payouts.** Several scans assumed a blacklisted investor's `fulfillWithdraw` would revert forever. Mainnet USDT checks only the *sender* (`require(!isBlackListed[msg.sender])`); the vault is the sender, so payouts to a blacklisted investor or introducer succeed. `test/DeosxVault.fork.t.sol` pays both on a mainnet fork. Only a blacklisted *vault* freezes everything. | Not an issue. |
| `cancelWithdraw` works while paused; `requestWithdraw` does not, so an investor who cancels during a pause waits for the unpause. | Intended: pause must never trap a request. |
| The opening minimum applies only when `capitalOf == 0`, and requests have no minimum: an investor who keeps 1 unit (or tops up while a full request is pending) can hold less than the opening minimum. | Policy only; no other party is affected. The spec chose no request minimum. |
| A deposit sized to the exact room left reverts if any deposit lands first (no partial fill). | The depositor previews and retries; nothing is lost. |
| Depositing into T1 or T2 and being repaid at once uses up that room for good. | The terms: a filled tranche never reopens. |
| A pending request keeps the tier split from `requestedAt`, and stores three tier buckets, not holding times. `positionsOf` shows reserved units at their **live** tier. | The Safe prices interest from the frozen split and the `Deposited` history (README, "Deciding interest"); never from `positionsOf`. |
| Interest is worked out off-chain per request, so many 1-unit requests could gain from a calculator that rounds up. | The Safe's calculator must round down. |
| A due introducer fee reserves no pot money; other payouts can empty the pot first, and `payIntroducerFee` then reverts until the Safe funds it. | The Safe funds the pot for interest **and** the fee before paying (README recipes). |
| One cancelled request makes a whole Safe batch revert (`NotPending`). | Simulate right before executing (README). |
| An operator can whitelist an address first and so make the Safe's `setOperator` or `transferOwnership` to it revert. | Needs a rogue operator; the Safe removes it in the same batch. No funds at risk. |
| With Tether's fee on, `returnCapital` credits the net amount, so `deployedCapital` keeps a small remainder that a second exact call clears. | Tether's fee is off today. |
