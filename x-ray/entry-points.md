# Entry Point Map

> DEOS-X Tranche Vault | 20 entry points | 0 permissionless | 7 role- or state-gated | 13 admin-only (Safe)

Scope: `src/DeosxVault.sol`, `src/TrancheToken.sol`. `src/testnet/` (TestTether, SepoliaFaucet) is Sepolia-only and excluded.

---

## Protocol Flow Paths

### Setup (Deployer → Safe)

`Deploy.deploy()` → `new DeosxVault(...)` (deploys `dxT1/dxT2/dxT3`) → `Safe.setOperator(backend, true)`

### Onboarding (Operator)

`[setup above]` → `setWhitelisted(wallet, true)` → `setIntroducer(wallet, introducer)` (optional)

### Investor Flow

`[onboarding above]` → `usdt.approve(vault, amount)` → `deposit(amount, minPieces)`  ◄── not paused, room left, minimum met
    └─→ `requestWithdraw(tranche, amount)`  ◄── not paused, no open request, amount ≤ capital in tranche
            ├─→ `cancelWithdraw(id)`  ◄── works while paused
            └─→ `Safe.fulfillWithdraw(id, interest)`  ◄── capital cash ≥ amount, tranche pot ≥ interest
                    └─→ `Safe.payIntroducerFee(id, fee)`  ◄── request recorded an introducer; pot ≥ fee

### Pots and Capital (Safe)

`[setup above]` → `fundInterest(tranche, x)` → … → `withdrawInterest(tranche, y)`  ◄── pot ≥ y
`[deposit above]` → `transferOut(to, x)`  ◄── capital cash ≥ x
    └─→ `returnCapital(y)`  ◄── y ≤ deployedCapital

---

## Permissionless

No function is callable by an arbitrary address with no state precondition. The two investor functions below have no modifier but are restricted by state (whitelist / request ownership); they are listed in full because they are the user-facing surface.

### `DeosxVault.requestWithdraw()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `whenNotPaused` (no `nonReentrant`; no external calls) |
| Caller | Any wallet holding capital (no whitelist check, so a removed wallet can still leave) |
| Parameters | tranche (user-controlled), amount (user-controlled, 1 … `_capitalIn`) |
| Call chain | `→ _checkTranche() → _snapshot()` (walks positions from `_head`) |
| State modified | `reserved`, `_requestCount`, `_requests[id]`, `_pending`, `openRequestOf` |
| Value flow | None |
| Reentrancy guard | no |

### `DeosxVault.cancelWithdraw()`

| Aspect | Detail |
|--------|--------|
| Visibility | external (works while paused) |
| Caller | Owner of the request (`r.owner == msg.sender`) |
| Parameters | requestId (user-controlled) |
| Call chain | none (storage only) |
| State modified | `reserved`, `_requests[id].status`, `_pending`, `openRequestOf` |
| Value flow | None |
| Reentrancy guard | no |

---

## Role-Gated

### Whitelisted wallet

#### `DeosxVault.deposit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant`, `whenNotPaused` |
| Caller | Whitelisted investor |
| Parameters | amount (user-controlled), minPieces[3] (user-controlled, from `previewDeposit`) |
| Call chain | `→ _pull() → USDT.safeTransferFrom() → _place() → TrancheToken.mint()` ×≤3 |
| State modified | `_positions`, `_capitalIn`, `_tranches[i].taken`, `_tranches[i].capital`, `capitalOf`, LP balances |
| Value flow | Tokens in: investor → vault |
| Reentrancy guard | yes |

### Operator (or owner) — `onlyOperator`

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| DeosxVault | `setWhitelisted()` | wallet, allowed | `isWhitelisted` (refuses operator / owner / pendingOwner) |
| DeosxVault | `setIntroducer()` | wallet, introducer | `introducerOf` (refuses vault, USDT, LP tokens) |

Neither is pausable.

### Vault only — `TrancheToken.onlyVault`

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| TrancheToken | `mint()` | to, amount (protocol-derived) | `_balances`, `_totalSupply` |
| TrancheToken | `burn()` | from, amount (protocol-derived) | `_balances`, `_totalSupply` |

`TrancheToken.approve()` always reverts; `transfer`/`transferFrom` revert in `_update`.

---

## Admin-Only

Owner = the Safe (`Ownable2Step`). None of these is pausable or timelocked.

#### `DeosxVault.fulfillWithdraw()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant`, `onlyOwner` |
| Caller | Safe |
| Parameters | requestId (keeper-provided), interest (keeper-provided, bounded only by the tranche pot) |
| Call chain | `→ _requireCapital() → _spendInterest() → _consumeOldest() → TrancheToken.burn() → USDT.safeTransfer(investor, amount + interest)` |
| State modified | `interestPot`, `totalInterestPot`, `_positions`, `_head`, `reserved`, `_capitalIn`, `capitalOf`, `_tranches[t].capital`, T3 `taken`, `_requests[id]`, `_pending`, `openRequestOf`, `_feesDue` |
| Value flow | Vault → investor |
| Reentrancy guard | yes |

#### `DeosxVault.transferOut()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `nonReentrant`, `onlyOwner` |
| Caller | Safe |
| Parameters | to (keeper-provided, any address except 0 / vault), amount (keeper-provided, ≤ capital cash) |
| Call chain | `→ _requireCapital() → USDT.safeTransfer(to, amount)` |
| State modified | `deployedCapital` |
| Value flow | Vault → any address |
| Reentrancy guard | yes |

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| DeosxVault | `payIntroducerFee()` | requestId, amount | `interestPot`, `totalInterestPot`, `_requests[id].feeStatus/fee`, `_feesDue`; USDT → recorded introducer |
| DeosxVault | `fundInterest()` | tranche, amount | `interestPot`, `totalInterestPot`; USDT Safe → vault |
| DeosxVault | `withdrawInterest()` | tranche, amount | `interestPot`, `totalInterestPot`; USDT vault → Safe |
| DeosxVault | `returnCapital()` | amount | `deployedCapital`; USDT Safe → vault |
| DeosxVault | `setOperator()` | operator, allowed | `isOperator` (refuses investors) |
| DeosxVault | `setMinimums()` | opening, topUp | `openingMinimum`, `topUpMinimum` |
| DeosxVault | `pause()` / `unpause()` | — | `_paused` (blocks only `deposit`, `requestWithdraw`) |
| DeosxVault | `transferOwnership()` | newOwner | `_pendingOwner` (refuses investors) |
| DeosxVault | `acceptOwnership()` (OZ, pendingOwner) | — | `_owner`, `_pendingOwner` |
| DeosxVault | `renounceOwnership()` | — | always reverts |

---

## Initialization

`DeosxVault` is not upgradeable; the constructor sets USDT, owner (Safe), tranche sizes, tier thresholds and minimums, and deploys the three `TrancheToken`s. `script/Deploy.s.sol` restricts to chain IDs 1 / 11155111, fixes mainnet settings, and checks the Safe has code and USDT has 6 decimals.
