// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeosxVault} from "../../src/DeosxVault.sol";
import {MockTether} from "../mocks/MockTether.sol";

/// @notice Shared setup: a vault on mainnet settings (50% tier after 60 days, 100% after 90, 2M / 3M / 15M
/// tranches, 100k / 10k minimums) over a Tether-like mock, owned by `safe`, with `operator` appointed and `alice`
/// and `bob` whitelisted. `carol` introduced `alice`.
abstract contract VaultTestBase is Test {
    uint64 internal constant HALF = 60 days;
    uint64 internal constant FULL = 90 days;
    uint64 internal constant T0 = 1_750_000_000;

    uint256 internal constant T1_SIZE = 2_000_000e6;
    uint256 internal constant T2_SIZE = 3_000_000e6;
    uint256 internal constant T3_SIZE = 15_000_000e6;
    uint256 internal constant OPENING = 100_000e6;
    uint256 internal constant TOPUP = 10_000e6;

    /// @dev `deposit`'s `minPieces` that accepts any split (all zeros).
    uint256[3] internal ANY_SPLIT;

    MockTether internal usdt;
    DeosxVault internal vault;

    address internal safe = makeAddr("safe");
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal otc = makeAddr("otc");

    function setUp() public virtual {
        vm.warp(T0);
        usdt = new MockTether();
        vault = new DeosxVault(IERC20Metadata(address(usdt)), safe, _sizes(), HALF, FULL, OPENING, TOPUP);
        vm.startPrank(safe);
        vault.setOperator(operator, true);
        vault.setWhitelisted(alice, true);
        vault.setWhitelisted(bob, true);
        vault.setIntroducer(alice, carol);
        vm.stopPrank();
    }

    function _sizes() internal pure returns (uint256[3] memory) {
        return [T1_SIZE, T2_SIZE, T3_SIZE];
    }

    /// @dev Approves the way the app must with real USDT: back to 0 first, then the amount.
    function _approve(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdt.approve(address(vault), 0);
        usdt.approve(address(vault), amount);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal {
        usdt.mint(who, amount);
        _approve(who, amount);
        vm.prank(who);
        vault.deposit(amount, ANY_SPLIT);
    }

    /// @dev Gives the Safe `amount` USDT and approves the vault for it, ready for `fundInterest` or `returnCapital`.
    function _fundSafe(uint256 amount) internal {
        usdt.mint(safe, amount);
        _approve(safe, amount);
    }

    function _fundInterest(uint256 tranche, uint256 amount) internal {
        _fundSafe(amount);
        vm.prank(safe);
        vault.fundInterest(tranche, amount);
    }

    function _request(address who, uint256 tranche, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestWithdraw(tranche, amount);
    }

    function _lp(uint256 tranche) internal view returns (IERC20Metadata) {
        return IERC20Metadata(vault.trancheInfo(tranche).lpToken);
    }
}
