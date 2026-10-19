# DEOS X Yield Fund — contracts (`deosx-contracts-personal`)

Foundry project for the DEOS X Yield Fund vault. This is the **current,
audit-scope copy** (personal repo github.com/noobstar3310/deosx-contracts).
`../deosx-yield/contracts` is an older copy with byte-identical `src/` but
stale tests/docs — never treat it as the source. Frontends:
`../deosx-yield` (investors/introducers) and `../admin-deosx-yield` (staff).
Read `README.md`, `KNOWN_ISSUES.md`, `docs/design-v2.md` and `x-ray/` first.
Last full review: 13 Oct 2026.

## Layout
- `src/DeosxVault.sol` (~660 lines) — `Ownable2Step, Pausable,
  ReentrancyGuard`; not upgradeable (no proxy). Deploys three `TrancheToken`s.
- `src/TrancheToken.sol` — ERC20 LP token per tranche (dxT1/2/3), mint/burn by
  vault only, non-transferable, `approve` reverts. 1:1 with capital.
- `src/testnet/` — `TestTether` (USDT-like, open mint up to 20M/call),
  `SepoliaFaucet` (0.005 ETH per 72 h, relayer drips).
- `script/` — `Deploy.s.sol` (chain 1 or 11155111 only; mainnet settings
  fixed), `DeployTestTether`, `DeploySepoliaFaucet` (Sepolia only).
- `test/` — config, deposit, withdraw, pots, auditFixes, gas, invariant
  (12 invariants, `handlers/VaultHandler.sol` 16 actions), fork (Sepolia +
  mainnet, skip without RPC), Deploy, TestTether, SepoliaFaucet.
  `mocks/MockTether` reproduces USDT quirks (no return value, zero-first
  approve, fee switch, blacklist).
- `abi/` — bare ABI JSON from `forge inspect`; must match `out/`. Frontends do
  **not** import these; they hand-encode selectors, so a signature change
  needs matching edits in both portals' `lib/*.ts`.

## Toolchain
- solc `0.8.30`, `evm_version = cancun`, optimizer 200 runs; fuzz 1000 runs;
  invariant 256×100, `fail_on_revert = true`.
- Deps: forge-std v1.16.2, OpenZeppelin Contracts v5.7.0 (submodules in
  `lib/`). `forge install` uses git — the user runs that.
- `forge test --offline` → 151 pass, 2 skipped (fork) as of 13 Oct 2026.
- CI `.github/workflows/test.yml`: `forge fmt --check`, `build --sizes`,
  `test -vvv`. Foundry version not pinned; no fork/coverage/static analysis.
- `Makefile` (Sepolia only, keystore account `TEIZA-dev-wallet`): `test`,
  `fork`, `dry-*`/`deploy-*` for tether/vault/faucet, `fund-faucet`,
  `addresses`, `mint`, `operator-check`, etc. Addresses come from
  `broadcast/*/11155111/run-latest.json`.

## Roles
| Role | Holder | Can do |
|---|---|---|
| Owner | Safe multisig (constructor arg; 2-step transfer; renounce reverts) | All money movement (`fundInterest`, `withdrawInterest`, `transferOut`, `returnCapital`, `fulfillWithdraw`, `payIntroducerFee`), `setOperator`, `setMinimums`, pause, plus operator powers |
| Operator | Backend / Operator staff wallet(s) | `setWhitelisted`, `setIntroducer` only |
| Investor | Whitelisted wallet (Privy embedded; whitelist the smart-wallet address if smart wallets are used) | `deposit`; any holder can `requestWithdraw` / `cancelWithdraw` |
| Introducer | Just `introducerOf[wallet]` | Nothing on-chain |
Staff and investor wallets are kept disjoint (`RoleConflict`).

## Model (v2)
- **Waterfall:** deposits fill T1 (2M) → T2 (3M) → T3 (15M); one deposit can
  split across tranches into positions. T1/T2 never reopen; T3 room reopens on
  payout. `deposit(amount, minPieces[3])` has a slippage guard; minimums
  (opening 100k / top-up 10k) except when exactly filling the last room.
- **No rates or cycles on-chain.** Rates (15/10/7% investor, 10/5/3%
  introducer) live in the portals/API. Holding tiers (0%/50%/100% at 60/90
  days; minutes on Sepolia) are informational.
- **Two money buckets per tranche:** capital (= LP supply) and interest pot.
  Capital cash = `balance − totalInterestPot`, so direct transfers become
  Safe-spendable capital.
- **Exit:** investor `requestWithdraw(tranche, amount)` (one open request per
  wallet, oldest positions first, tier split frozen) → Safe
  `fulfillWithdraw(id, interest)` pays capital + Safe-chosen interest from the
  pot → introducer fee becomes Due → Safe `payIntroducerFee(id, amount)`.
- No on-chain math beyond add/sub; off-chain calculators must round down.

## Deployments (Sepolia 11155111; no mainnet yet)
- Vault `0x92044eee09bc53f8d254bde733283e5255352a46` — ⚠ **pre-audit-fix
  build** (has `deposit(uint256)`, not `deposit(uint256,uint256[3])`; lacks the
  5 Oct fixes). Does not match `abi/`. Needs a redeploy.
- TestTether `0xac33f56e6ee2da84ecb66253a3917c0132a8ce06`;
  SepoliaFaucet `0xe1a24f01de9bb500deaf4b7d55a743bcba7e2b7a`;
  retired v1 vault `0x261cf2ed518b61dd5fa94217b536939bf566d5bd`.
- Env names: `SAFE_ADDRESS`, `USDT_ADDRESS`, `HALF_TIER_AFTER`,
  `FULL_TIER_AFTER`, `OPENING_MINIMUM`, `TOPUP_MINIMUM`, `RELAYER_ADDRESS`,
  `SEPOLIA_RPC_URL`, `MAINNET_RPC_URL`, `ETHERSCAN_API_KEY`.

## Open design questions / pre-mainnet gaps
- Business wants interest paid every 90-day cycle; the vault only pays
  interest (and makes the introducer fee due) on a capital withdrawal.
- No admin-initiated redemption, wind-down or lost-wallet recovery.
- `topUpMinimum ≥ 5,500 USDT` gas rule (KNOWN_ISSUES §2) is not enforced in
  `setMinimums`.
- `transferOut` has no cap/timelock; one Safe is admin, treasurer and payer.
- No permit/meta-tx: Privy wallets need ETH or a paymaster on mainnet.
- Audit so far is an AI scan (`x-ray/`, `auditFixes`); get an external audit.
- CI: pin Foundry, run fork tests, add coverage + Slither/Aderyn + a second
  fuzzer.

## Conventions
- Custom errors, NatSpec, events for every state change; keep invariants in
  `x-ray/invariants.md` in sync with `test/DeosxVault.invariant.t.sol`.
- After changing `src/`, regenerate `abi/` (see README) and tell the user the
  portals' hand-encoded selectors may need updating.
- Run `forge fmt` before finishing (CI checks it).
