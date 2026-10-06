// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DeosxVault} from "../src/DeosxVault.sol";

uint256 constant MAINNET_CHAIN_ID = 1;
uint256 constant SEPOLIA_CHAIN_ID = 11155111;
address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

/// @notice Deploys DeosxVault owned by the Safe, on Ethereum mainnet or Sepolia only. Required env: SAFE_ADDRESS.
/// Settings come from the chain. On Sepolia USDT_ADDRESS is required (the team's `TestTether`, deployed with
/// DeployTestTether), and any of HALF_TIER_AFTER, FULL_TIER_AFTER (seconds), OPENING_MINIMUM, TOPUP_MINIMUM (USDT
/// base units) overrides the defaults. On mainnet the settings are fixed: a stray
/// override reverts instead of changing terms that can never be changed again. The tranche sizes are the fund's and
/// are the same on both chains.
contract Deploy is Script {
    struct Settings {
        address usdt;
        uint64 halfTierAfter;
        uint64 fullTierAfter;
        uint256 openingMinimum;
        uint256 topUpMinimum;
    }

    error UnsupportedChain(uint256 chainId);
    error MainnetSettingsAreFixed();
    error SafeHasNoCode(address safe);
    error UsdtNotSet();
    error UsdtNotSixDecimals(uint8 decimals);

    function run() external returns (DeosxVault) {
        return deploy(vm.envAddress("SAFE_ADDRESS"), withEnvOverrides(defaults(block.chainid)));
    }

    /// @notice Mainnet and Sepolia share the dollar amounts; Sepolia compresses the clock (one day = one minute).
    function defaults(uint256 chainId) public pure returns (Settings memory s) {
        if (chainId == MAINNET_CHAIN_ID) {
            s = Settings({
                usdt: MAINNET_USDT,
                halfTierAfter: 60 days,
                fullTierAfter: 90 days,
                openingMinimum: 100_000e6,
                topUpMinimum: 10_000e6
            });
        } else if (chainId == SEPOLIA_CHAIN_ID) {
            s = Settings({
                usdt: address(0), // no default: USDT_ADDRESS must name the deployed TestTether
                halfTierAfter: 60 minutes,
                fullTierAfter: 90 minutes,
                openingMinimum: 100_000e6,
                topUpMinimum: 10_000e6
            });
        } else {
            revert UnsupportedChain(chainId);
        }
    }

    function sizes() public pure returns (uint256[3] memory) {
        return [uint256(2_000_000e6), 3_000_000e6, 15_000_000e6];
    }

    function withEnvOverrides(Settings memory s) public view returns (Settings memory) {
        s.usdt = vm.envOr("USDT_ADDRESS", s.usdt);
        s.halfTierAfter = SafeCast.toUint64(vm.envOr("HALF_TIER_AFTER", uint256(s.halfTierAfter)));
        s.fullTierAfter = SafeCast.toUint64(vm.envOr("FULL_TIER_AFTER", uint256(s.fullTierAfter)));
        s.openingMinimum = vm.envOr("OPENING_MINIMUM", s.openingMinimum);
        s.topUpMinimum = vm.envOr("TOPUP_MINIMUM", s.topUpMinimum);
        return s;
    }

    /// @notice Every path to a deployment ends here, so the checks cannot be skipped by calling this directly.
    function deploy(address safe, Settings memory s) public returns (DeosxVault vault) {
        if (block.chainid != MAINNET_CHAIN_ID && block.chainid != SEPOLIA_CHAIN_ID) {
            revert UnsupportedChain(block.chainid);
        }
        if (
            block.chainid == MAINNET_CHAIN_ID
                && keccak256(abi.encode(s)) != keccak256(abi.encode(defaults(MAINNET_CHAIN_ID)))
        ) revert MainnetSettingsAreFixed();
        if (safe.code.length == 0) revert SafeHasNoCode(safe);
        if (s.usdt == address(0)) revert UsdtNotSet();
        uint8 usdtDecimals = IERC20Metadata(s.usdt).decimals();
        if (usdtDecimals != 6) revert UsdtNotSixDecimals(usdtDecimals);

        // Printed by the dry run too: read them before broadcasting. The USDT address and the two tier times can
        // never change after deployment; the owner only by a two-step handover; the minimums by the Safe.
        console2.log("chain id          ", block.chainid);
        console2.log("safe (owner)      ", safe);
        console2.log("usdt              ", s.usdt);
        console2.log("halfTierAfter (s) ", s.halfTierAfter);
        console2.log("fullTierAfter (s) ", s.fullTierAfter);
        console2.log("openingMinimum    ", s.openingMinimum);
        console2.log("topUpMinimum      ", s.topUpMinimum);

        vm.startBroadcast();
        vault = new DeosxVault(
            IERC20Metadata(s.usdt), safe, sizes(), s.halfTierAfter, s.fullTierAfter, s.openingMinimum, s.topUpMinimum
        );
        vm.stopBroadcast();
    }
}
