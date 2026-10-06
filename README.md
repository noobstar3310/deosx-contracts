# DEOS-X tranche vault contracts

The on-chain vault of the Stablecoin Yield Fund. Investors deposit USDT from the app; the contract places every deposit into the fund's three tranches and mints that tranche's LP token 1:1. The admin, a Safe multisig, deploys the capital, pre-funds interest, and signs every payout.

**The contract calculates no interest.** Each tranche has two pots: its **capital** (always equal to its LP supply) and an **interest pot** the Safe tops up. When an investor withdraws, they get their capital back 1:1 plus an interest amount the Safe decides and pays from that tranche's interest pot. The introducer's fee is paid separately, later, from the same pot. The contract records how long each part of a position has been held so the Safe can decide.

Design: [`docs/design-v2.md`](docs/design-v2.md).

## Audit scope

| File | nSLOC | |
| --- | ---: | --- |
| [`src/DeosxVault.sol`](src/DeosxVault.sol) | 482 | The vault: tranches, positions, requests, pots, payouts, roles |
| [`src/TrancheToken.sol`](src/TrancheToken.sol) | 35 | The non-transferable LP token the vault deploys, one per tranche |

- **Out of scope:** `src/testnet/` (`TestTether`, `SepoliaFaucet`: Sepolia-only helpers, never deployed on mainnet), `script/` and `test/`. `script/Deploy.s.sol` fixes the mainnet settings and is worth a read for context.
- **Target:** Ethereum mainnet, with mainnet USDT (`0xdAC17F958D2ee523a2206206994597C13D831ec7`). Not upgradeable.
- **Toolchain:** Solidity 0.8.30 (`evm_version = cancun`, optimizer 200 runs), OpenZeppelin Contracts v5.7.0, forge-std v1.16.2 (pinned in `foundry.lock`).
- **Trust model:** the owner is a Safe multisig and is trusted with every money movement; operators (the portal backend) are trusted only for the whitelist and introducer records.
- **Known and accepted behaviour:** [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md). Please report those only with an impact beyond what is described there.
- **Pre-audit material:** [`x-ray/`](x-ray/x-ray.md): threat model, [entry points](x-ray/entry-points.md) and [invariants](x-ray/invariants.md).

## Networks

| | Ethereum Sepolia (rehearsal) | Ethereum mainnet |
| --- | --- | --- |
| Chain ID | `11155111` | `1` |
| Vault | [`0x92044EeE09Bc53F8D254bde733283e5255352a46`](https://sepolia.etherscan.io/address/0x92044EeE09Bc53F8D254bde733283e5255352a46) | not deployed yet (after the audit) |
| Admin (Safe) | `0xf6ae15BB022886832814F3980303A0d9e65E5dE5` | not deployed yet |
| USDT (6 decimals) | [`0xAC33F56E6EE2dA84ECB66253A3917c0132A8ce06`](https://sepolia.etherscan.io/address/0xAC33F56E6EE2dA84ECB66253A3917c0132A8ce06) (`TestTether`, the team's own) | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| LP tokens (`vault.trancheInfo(0 / 1 / 2).lpToken`) | dxT1 `0xe5A9286e24ED4Fd17C2038a56bD8F6E0318766dB`, dxT2 `0xa25f8bF33aEb561eA4870386D300cB07AcdC1CaE`, dxT3 `0x48c4BBA6E75d1a52d2d37d4C0AB0ad975F049143` | not deployed yet |
| ABIs | [`abi/DeosxVault.json`](abi/DeosxVault.json), [`abi/TrancheToken.json`](abi/TrancheToken.json), [`abi/TestTether.json`](abi/TestTether.json) | same, without `TestTether` |

The first Sepolia vault (`0x261CF2ED518B61DD5fa94217b536939bf566d5BD`) and its faucet are retired: that vault is the previous design, and the Sepolia Test Tether (`0x7169D38820dfd117C3FA1f22a697dBA58d90BA06`) behind the faucet can no longer mint, because someone pushed its total supply to the uint256 maximum.

Amounts are in USDT base units: 1 USDT = `1_000_000`. LP tokens have the same 6 decimals.

| Setting | Sepolia | Mainnet |
| --- | --- | --- |
| Tranche sizes | T1 2,000,000; T2 3,000,000; T3 15,000,000 | same |
| `halfTierAfter()` (50% interest eligibility from) | 60 minutes | 60 days |
| `fullTierAfter()` (100% interest eligibility from) | 90 minutes | 90 days |
| `openingMinimum()` / `topUpMinimum()` | 100,000 / 10,000 | same |

Sepolia is mainnet with the clock compressed: same dollar amounts, one day of the real schedule is one minute.

## How it works

**Tranches.** A deposit fills T1's room, then T2's, then T3's; one that straddles a boundary is split (5,000,000 into an empty fund is 2,000,000 in T1 and 3,000,000 in T2). T1 and T2 never reopen: their room counts everything ever deposited. T3 reopens when capital is paid out of it, first come first served. When there is no room, deposits are refused. Room left: `trancheInfo(0).room + trancheInfo(1).room + trancheInfo(2).room`.

**Positions.** Each piece of a deposit is a **position** in one tranche with its own deposit time. A top-up opens a new position, so every part keeps its own clock. A withdrawal request takes the wallet's oldest units in its tranche, and its payout removes exactly those.

**LP tokens.** `dxT1`, `dxT2`, `dxT3`: one LP per USDT of capital in that tranche. Minted on deposit, burned on payout, never transferable (`transfer` and `approve` revert with `SharesNonTransferable()`; `transferFrom` reverts first with OpenZeppelin's `ERC20InsufficientAllowance`, since no allowance can ever be set). LP is always worth exactly 1 USDT of capital; interest is paid on top, outside the token.

**Eligibility tiers.** From each position's deposit time: under `halfTierAfter` is tier 0%, from `halfTierAfter` 50%, from `fullTierAfter` 100%. The contract only reports the tier; the Safe decides the interest. Nothing is enforced.

**Interest pots.** The Safe pre-funds each tranche's pot with `fundInterest(tranche, amount)` and can take unused interest back with `withdrawInterest`. Interest and introducer fees for a withdrawal come only from that tranche's pot. Capital can never be paid out of a pot, and `transferOut` can never take from one.

## Investor UI

**Whitelist.** Only whitelisted wallets can deposit. The backend whitelists each new Privy wallet (see Backend). If you use Privy **smart wallets**, whitelist the smart-wallet address, not its signer. Anything else gets `NotWhitelisted(wallet)`; read `vault.isWhitelisted(wallet)` beforehand. A wallet taken off the whitelist can still request, cancel and be paid.

**Get test USDT (Sepolia only).** `testTether.mint(userAddress, amount)` on `0xAC33F56E6EE2dA84ECB66253A3917c0132A8ce06`, anyone, up to 20,000,000 USDT (`20_000_000_000_000`) per call. From a terminal: `make mint TO=0xUser AMOUNT=100000` (whole USDT).

**Deposit.**

1. Preview with `vault.previewDeposit(amount)`: returns `uint256[3]`, the amount landing in T1, T2, T3. It reverts with `ExceedsCapacity(room)` if the amount doesn't fit, and doesn't check the whitelist, the minimum or the pause. A deposit mined first can change the split, so pass this preview to `deposit` as `minPieces` (step 3).
2. Approve. **USDT rejects changing one non-zero allowance to another.** If `usdt.allowance(user, vault)` is not 0, send `usdt.approve(vault, 0)` first, then `usdt.approve(vault, amount)`. USDT's `approve` returns nothing; use an ABI without a return value or a library that tolerates it. `TestTether` behaves the same way.
3. `vault.deposit(amount, minPieces)` emits `Deposited(wallet, amount, perTranche)`. `minPieces` (`uint256[3]`) is the least the user accepts in T1, T2 and T3: pass the `previewDeposit(amount)` result. If another deposit mined first changed the split, the call reverts with `PlacementChanged(tranche, placed, minimum)` instead of landing in a lower-rate tranche; preview again and ask the user to confirm the new split. `[0, 0, 0]` accepts any split. Check `usdt.balanceOf(user)` and the allowance first: on mainnet, when either is short, USDT reverts with no error data and uses up all the gas sent.

Minimums: a wallet holding no capital in any tranche (`capitalOf(wallet) == 0`) needs `openingMinimum()`; otherwise a top-up needs `topUpMinimum()`. After a full withdrawal the next deposit is an opening one again. A deposit of exactly all the room left in the fund is exempt from the minimum, so the last room can always be filled. The Safe can change both, so read them instead of hard-coding 100,000 and 10,000. Errors: `BelowMinimum(amount, minimum)`, `ExceedsCapacity(room)`.

**Show positions.**

| Read | Returns |
| --- | --- |
| `positionsOf(user, tranche)` | Open positions in that tranche, oldest first: `amount`, `depositedAt`, `heldFor` (seconds), `tierBps` (`0`, `5000` or `10000`). `heldFor` and `tierBps` are as of **now**; a request's split is measured at its `requestedAt` (see Withdraw). |
| `available(user, tranche)` | Capital the user can still ask to withdraw (not already in their pending request). |
| `reserved(user, tranche)` | Capital in the user's pending request, if it is in that tranche; else 0. |
| `openRequestOf(user)` | The user's pending request ID, across all tranches; `0` if none. While it is not 0, show that request (with Cancel) instead of a new-request form. |
| `capitalOf(user)` | Capital across all three tranches. |
| LP `balanceOf(user)` | Same as the sum of `positionsOf` amounts for that tranche. |

**Withdraw.** `vault.requestWithdraw(tranche, amount)` returns a request ID and emits `WithdrawRequested(id, owner, tranche, amount, heldUnderHalf, heldHalf, heldFull)`: the request's **split**, how much of the amount was held under the 50% tier, in the 50% tier and in the 100% tier at the moment of the request (`requestedAt`). The amount can be anything from 1 unit up to `available(user, tranche)`: there is no minimum. Otherwise it reverts with `ExceedsAvailable(available, amount)`. **One open request per investor:** a wallet can have only one pending request at a time, across all tranches; while it has one (`openRequestOf(user) != 0`), a new request reverts with `RequestPending(id)`. Cancel it or wait for it to be paid, then request again. The request takes the wallet's oldest units in that tranche. Its split is final: measured at `requestedAt`, it doesn't age while the request waits, and it is the split the request is paid on; `getRequest(id)` returns the same figures as the event. Nothing moves yet: the LP stays with the user until the Safe pays.

**Cancel.** `vault.cancelWithdraw(id)` while it is pending; the capital becomes available again.

**Getting paid.** USDT arrives when the Safe runs `fulfillWithdraw`: capital 1:1 plus the interest the Safe decided, and the LP is burned. Read the outcome with `getRequest(id)` (`status` `3` Paid, `interest`).

Deposits and new requests fail with `EnforcedPause()` while the vault is paused (`vault.paused()`); cancelling and every Safe action still work.

## Backend (operator key)

The Safe appoints operators with `setOperator(address, true)` and removes them with `false`; several can be active. An operator (or the Safe) can only:

| Call | Effect |
| --- | --- |
| `setWhitelisted(wallet, true / false)` | Allow or stop deposits from `wallet`. |
| `setIntroducer(wallet, introducer)` | Record who introduced `wallet` (zero for none). A withdrawal request takes the introducer the wallet has when the request is made. |

Call `setWhitelisted` when a user signs up, and `setIntroducer` if they were introduced. Both revert with `ZeroAddress()` for a zero wallet and `NotOperator()` from any other key; `setIntroducer` reverts with `InvalidRecipient(address)` if the introducer is the vault itself, the USDT contract or an LP token (a fee paid to any of them could never be spent). A leaked operator key can whitelist wallets and change introducers on future requests, but can't move funds; the Safe removes it with `setOperator(key, false)`.

**Staff and investors are kept apart.** An operator, the Safe, or a Safe that is about to take over can't be whitelisted, and an investor (a wallet that is whitelisted **or still holds capital**) can't be made an operator or the owner: those calls revert with `RoleConflict(wallet)`. Removing someone from either list always works, so to move an investor into a staff role, take it off the whitelist and pay out all its capital first.

## Admin UI (Safe)

Every write is a Safe transaction: build it in the Safe{Wallet} Transaction Builder with the vault address and [`abi/DeosxVault.json`](abi/DeosxVault.json), or with the Safe SDK.

| Read | Returns |
| --- | --- |
| `vaultState()` | `(usdtInVault, capitalOwed, interestPots, capitalCash, deployed)`. `capitalOwed` is all LP outstanding; `capitalCash` is what `transferOut` and capital payouts can use (`usdtInVault − interestPots`, or 0 if the vault ever holds less than its pots); `deployed` is what `transferOut` sent and `returnCapital` hasn't brought back. |
| `trancheInfo(i)` | `size`, `taken`, `room`, `capital`, `interestPot`, `lpToken`. |
| `pendingRequests()` | Request IDs waiting to be paid, in no particular order. Build the admin queue from the `WithdrawRequested` / `WithdrawFulfilled` / `WithdrawCancelled` events and use this to confirm. |
| `getRequest(id)` | `owner`, `tranche`, `requestedAt`, `status` (`1` Pending, `2` Cancelled, `3` Paid), `feeStatus` (`0` none, `1` Due, `2` Paid), `introducer` (the investor's introducer when the request was made), `amount`, `heldUnderHalf`, `heldHalf`, `heldFull`, `interest`, `fee`. The three held figures are the split measured at `requestedAt`, never at the payout; they are fixed when the request is made and the request is paid on them. |
| `feesDue()` | Paid request IDs whose introducer fee hasn't been paid or closed. |
| `positionsOf(owner, tranche)` | The investor's position detail, if the split isn't enough. Its `tierBps` is the tier **now**, not at the request: never sign interest from it; use `getRequest`'s split. `depositedAt` is fixed, so it does give each unit's age at `requestedAt`. |

| Write (Safe) | Effect |
| --- | --- |
| `fulfillWithdraw(id, interest)` | Burns the request's LP, sends `amount + interest` to the investor. `interest` (0 allowed) comes from that tranche's pot. If the request recorded an introducer (the investor's introducer when the request was made, `getRequest(id).introducer`), the fee becomes due (`IntroducerFeeDue(id, introducer)`). |
| `payIntroducerFee(id, amount)` | Once per paid request: sends `amount` from that tranche's pot to the introducer recorded on the request, even if the investor's introducer has changed since. `0` closes it without paying. |
| `fundInterest(tranche, amount)` | Pulls USDT from the Safe into that tranche's interest pot. Approve first. |
| `withdrawInterest(tranche, amount)` | Sends unused interest from that pot back to the Safe. |
| `transferOut(to, amount)` | Sends capital-side USDT anywhere (never interest pots); adds to `deployedCapital`. |
| `returnCapital(amount)` | Pulls USDT from the Safe; subtracts from `deployedCapital`. Approve first. At most `deployedCapital`. |
| `pause()` / `unpause()` | Stops or restarts deposits and new requests. |
| `setOperator(address, bool)` | Appoints or removes a backend operator. A wallet that is whitelisted or still holds capital can't be appointed (`RoleConflict`). |
| `setMinimums(opening, topUp)` | In base units: `setMinimums(100000000000, 10000000000)` is 100,000 and 10,000 USDT. `topUp` must be above 0 and at most `opening` (`InvalidConfig()` otherwise; the constructor checks the same). Both apply to deposits only; withdrawal requests have no minimum. |
| `transferOwnership(newSafe)`, then `acceptOwnership()` from the new Safe | Hands the vault to another Safe in two steps. `renounceOwnership()` always reverts. |

**Deciding interest.** The figures to use are `getRequest(id)`'s `heldUnderHalf`, `heldHalf` and `heldFull`, read just before signing. They are the request's split measured at its `requestedAt`: how much of it the investor had held long enough for 0%, 50% and 100% of its interest when they asked. The rate and the period interest accrues over are the fund's terms in the portal (`lib/fund.ts`), which are the authority; the contract only supplies the tiers. For example, if the terms pay T1's 15% p.a. for the days each unit was held up to `requestedAt`, and a 100,000 USDT request is one position deposited 75 days before `requestedAt` (so `heldHalf` = 100,000), the payout is 100,000 × 15% × 75 ÷ 365 × 50% ≈ 1,541.10 USDT on top of the capital. The contract doesn't check the figure; the Safe signers do. Each investor has at most one request pending, so `pendingRequests()` is never longer than the number of investors.

**Recipes** (one Safe transaction each, using the Transaction Builder's batch):

- **Pay a withdrawal:** `fulfillWithdraw(id, interest)`. If the tranche's pot is short: `usdt.approve(vault, x)`, `fundInterest(tranche, x)`, `fulfillWithdraw(id, interest)`, with `x` enough for the interest **and** the introducer fee that will follow from the same pot. If Tether's fee is ever on, `fundInterest(x)` credits less than `x`: check `trancheInfo(tranche).interestPot` (or the `InterestFunded` amount) covers both.
- **Short of capital** (`InsufficientCapital(available, needed)`): `usdt.approve(vault, amount)`, `returnCapital(amount)`, `fulfillWithdraw(id, interest)`.
- **Then the fee:** for each ID in `feesDue()`, check `getRequest(id).introducer` against the portal's record of who introduced the investor (the vault pays whoever the request recorded), then `payIntroducerFee(id, fee)`.

Approve exactly the amount each call pulls, so the allowance is back at 0 and USDT won't reject the next `approve`. If `usdt.allowance(safe, vault)` is not 0 (an earlier batch failed part-way), start the batch with `usdt.approve(vault, 0)`. If the investor cancels after a batch was proposed, `fulfillWithdraw` reverts with `NotPending()`: simulate right before executing. USDT sent to the vault with a plain transfer lands on the capital side, untracked: use `fundInterest` or `returnCapital`.

**What the vault owes:** `capitalOwed` to investors in capital, plus whatever interest and fees the Safe has promised, which only the Safe knows. Everything the vault holds is either `interestPots` or capital cash, and `capitalCash + deployed = capitalOwed` as long as nothing arrives outside the vault's functions.

## Events

| Event | When |
| --- | --- |
| `Deposited(wallet, amount, perTranche)` | Deposit. |
| `WithdrawRequested(id, owner, tranche, amount, heldUnderHalf, heldHalf, heldFull)` | Request made. |
| `WithdrawCancelled(id, owner)` | Request cancelled. |
| `WithdrawFulfilled(id, owner, tranche, amount, interest)` | Payout sent. |
| `IntroducerFeeDue(id, introducer)` | Payout made for an introduced investor: prompt the admin. |
| `IntroducerFeePaid(id, introducer, amount)` | Fee paid or closed (0). |
| `InterestFunded(tranche, amount)`, `InterestWithdrawn(tranche, amount)` | Interest pot in and out. |
| `CapitalTransferredOut(to, amount)`, `CapitalReturned(amount)` | Capital out and back. |
| `WhitelistSet(wallet, allowed)`, `IntroducerSet(wallet, introducer)`, `OperatorSet(operator, allowed)`, `MinimumsSet(opening, topUp)` | Settings. |
| `Paused`, `Unpaused`, `OwnershipTransferStarted`, `OwnershipTransferred` | OpenZeppelin's, for the pause and the two-step ownership handover. |

## Errors worth showing to users

| Error | Meaning |
| --- | --- |
| `NotWhitelisted(wallet)` | This wallet isn't registered to invest yet. |
| `BelowMinimum(amount, minimum)` | Below the minimum for a first deposit or a top-up. Show `minimum`. |
| `ExceedsCapacity(room)` | The fund has only `room` left. |
| `PlacementChanged(tranche, placed, minimum)` | Another deposit changed the split since the preview. Preview again and confirm with the user. |
| `ExceedsAvailable(available, amount)` | Asked to withdraw more than is free in that tranche. |
| `RequestPending(id)` | You already have a withdrawal request waiting; cancel it or wait for it to be paid. |
| `ZeroAmount()` | Amount was 0. |
| `NotRequestOwner()`, `NotPending()`, `UnknownRequest(id)` | Not your request, already paid or cancelled, or no such request. |
| `UnknownTranche(i)` | Tranche index above 2. |
| `EnforcedPause()` | The vault is paused. |
| `SharesNonTransferable()` (on the LP token) | LP tokens can't be transferred. |

Admin and backend side: `InsufficientCapital(available, needed)`, `InsufficientInterest(available, needed)`, `FeeNotDue(id)`, `ExceedsDeployed(deployed, amount)`, `InvalidRecipient(to)` (also `setIntroducer` with the vault, USDT or an LP token as introducer), `InvalidConfig()` (`setMinimums` or the constructor's settings out of bounds), `NotOperator()`, `RoleConflict(account)` (whitelisting staff, or making a whitelisted wallet or one that holds capital an operator or owner), `ZeroAddress()`, `OwnableUnauthorizedAccount(account)` when a Safe-only function is called by anyone else.

## Real USDT

- Tether can turn on a transfer fee (it is 0 today). Deposits, `fundInterest` and `returnCapital` credit only what arrives; payouts, introducer fees, `withdrawInterest` and `transferOut` would arrive less the fee.
- If Tether ever destroys or seizes USDT in the vault so it holds less than its interest pots, `vaultState()` reports `capitalCash` as 0 and capital payouts revert with `InsufficientCapital(0, needed)`.
- If Tether blacklists the vault, nothing can move. That is outside any contract's control. A blacklisted investor can still be paid: Tether stops a blacklisted address from sending, not from receiving (the mainnet fork test pays one).
- `TestTether` on Sepolia copies USDT's return values and approve rule, without the fee and blacklist.

## Development

Requires [Foundry](https://getfoundry.sh). From the repo root:

```bash
git submodule update --init --recursive   # first time only
forge build
forge test                                # fork tests are skipped
SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-contract Sepolia
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract Mainnet
# after changing a contract, export its ABI again:
forge inspect src/DeosxVault.sol:DeosxVault abi --json > abi/DeosxVault.json
forge inspect src/TrancheToken.sol:TrancheToken abi --json > abi/TrancheToken.json
forge inspect src/testnet/TestTether.sol:TestTether abi --json > abi/TestTether.json
```

`forge test` should end with `Ran 12 test suites`. If it reports fewer, forge's build cache has gone stale and is silently leaving a file out: run `forge build --force` and test again.

### Deploy

**Short way (Sepolia): the Makefile.** From the repo root, with `SAFE_ADDRESS`, `ETHERSCAN_API_KEY` and `SEPOLIA_RPC_URL` in `.env` (git-ignored) and the deployer keystore `TEIZA-dev-wallet` (override with `ACCOUNT=…`):

| Command | Does |
| --- | --- |
| `make dry-tether`, `make deploy-tether` | Simulate, then deploy and verify `TestTether`. |
| `make dry-vault`, `make deploy-vault` | Simulate, then deploy and verify the vault, using the `TestTether` from the last deploy (or `TETHER=0x…`). Read the settings the dry run prints before deploying. |
| `make addresses` | Prints `TestTether`, the vault and the three LP tokens from the last deploy. |
| `make check` | Reads the vault's owner, USDT, tier times and minimums on-chain. |
| `make operator-check OP=0x…` | Is `OP` an operator? |
| `make mint TO=0x… AMOUNT=100000` | Mints test USDT (whole USDT). |
| `make test`, `make fork` | Runs the tests; the fork tests against live Sepolia and mainnet. |

Nothing in the Makefile touches mainnet, and it never prints the Etherscan key. The long way, which mainnet uses:

The deploy script picks settings from the chain ID, refuses a Safe address with no code, checks USDT has 6 decimals, and prints the settings it is about to deploy: read them in a dry run (the same command without `--account deployer --broadcast --verify …`, plus `--sender <deployer address>`) before broadcasting, because the USDT address and the tier times can never be changed. It deploys to Ethereum mainnet and Sepolia only. On Sepolia `USDT_ADDRESS` is required (the `TestTether` address), and `HALF_TIER_AFTER`, `FULL_TIER_AFTER` (seconds), `OPENING_MINIMUM` and `TOPUP_MINIMUM` (base units) override the defaults (`TOPUP_MINIMUM` must be above 0 and at most `OPENING_MINIMUM`, or the constructor reverts with `InvalidConfig()`, which the dry run shows); on mainnet an override that changes any setting stops the deploy with `MainnetSettingsAreFixed()`. The vault deploy uses about 5.8M gas (forge's estimate).

1. Create the admin Safe on the target chain at [app.safe.global](https://app.safe.global).
2. Import a funded deployer key once: `cast wallet import deployer --interactive`.
3. Sepolia only: deploy the test USDT.

```bash
forge script script/DeployTestTether.s.sol:DeployTestTether \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com --account deployer --broadcast \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

4. Deploy and verify the vault:

```bash
SAFE_ADDRESS=0xYourSafe USDT_ADDRESS=0xTestTether forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com --account deployer --broadcast \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

5. From the Safe: `setOperator(backendKey, true)` for each backend key.

Mainnet is deployed the same way with `--rpc-url https://ethereum-rpc.publicnode.com` and no `USDT_ADDRESS`, **only after the external audit**, and never with `TestTether`.
