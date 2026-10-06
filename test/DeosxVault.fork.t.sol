// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeosxVault} from "../src/DeosxVault.sol";
import {TestTether} from "../src/testnet/TestTether.sol";

interface ITetherAdmin {
    function owner() external view returns (address);
    function addBlackList(address evilUser) external;
    function isBlackListed(address who) external view returns (bool);
}

/// @notice The whole flow on a live chain, with the vault deployed by the real deploy script: whitelist, deposit,
/// fund an interest pot, send capital out, request after the full tier, capital back, payout with interest,
/// introducer fee. Along the way it checks the token's quirks where the app and the vault meet them: `transfer`
/// and `approve` return nothing and a non-zero allowance can't be changed directly; on mainnet also that a
/// blacklisted address can't send but can still be paid, both as the investor and as the introducer.
abstract contract ForkFlow is Test {
    using SafeERC20 for IERC20;

    DeosxVault internal vault;
    IERC20 internal usdt;
    address internal safe = makeAddr("safe");
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal carol = makeAddr("carol");

    /// Deploys through `Deploy.deploy`, so the script's chain, Safe and decimals checks run against the live chain.
    function _deployVault(address usdtOverride) internal {
        vm.etch(safe, hex"00"); // stands in for a deployed Safe
        Deploy script = new Deploy();
        Deploy.Settings memory s = script.defaults(block.chainid);
        if (usdtOverride != address(0)) s.usdt = usdtOverride;
        usdt = IERC20(s.usdt);
        vault = script.deploy(safe, s);
        assertEq(vault.owner(), safe);

        vm.prank(safe);
        vault.setOperator(operator, true);
        vm.startPrank(operator);
        vault.setWhitelisted(alice, true);
        vault.setIntroducer(alice, carol);
        vm.stopPrank();
    }

    /// Needs `amount` USDT at alice and `amount / 4` at the Safe.
    /// With `blacklist`, Tether blacklists alice and carol before they are paid.
    function _runFlow(uint256 amount, bool blacklist) internal {
        assertEq(IERC20Metadata(address(usdt)).decimals(), 6);
        uint256 interest = amount * 15 / 100;
        uint256 fee = amount / 10;
        uint256 extra = blacklist ? 1 : 0; // the unit alice is given to prove she can't send

        vm.startPrank(alice);
        usdt.forceApprove(address(vault), 1);
        // A leftover allowance: real USDT refuses to change it directly, so the app must go through zero.
        (bool changed,) = address(usdt).call(abi.encodeCall(IERC20.approve, (address(vault), amount)));
        assertFalse(changed);
        usdt.forceApprove(address(vault), amount);
        vault.deposit(amount, [uint256(0), 0, 0]);
        vm.stopPrank();
        assertEq(IERC20(vault.trancheInfo(0).lpToken).balanceOf(alice), amount);

        vm.startPrank(safe);
        usdt.forceApprove(address(vault), interest + fee);
        vault.fundInterest(0, interest + fee);
        vault.transferOut(safe, amount);
        vm.stopPrank();
        assertEq(usdt.balanceOf(address(vault)), interest + fee);

        vm.warp(block.timestamp + vault.fullTierAfter());
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(0, amount);
        assertEq(vault.getRequest(id).heldFull, amount);

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InsufficientCapital.selector, 0, amount));
        vault.fulfillWithdraw(id, interest);

        if (blacklist) {
            ITetherAdmin tether = ITetherAdmin(address(usdt));
            vm.startPrank(tether.owner());
            tether.addBlackList(alice);
            tether.addBlackList(carol);
            vm.stopPrank();
            assertTrue(tether.isBlackListed(alice));
            assertTrue(tether.isBlackListed(carol));
            // Blacklisted addresses can't send: give alice 1 unit so only the blacklist can make this fail.
            deal(address(usdt), alice, 1);
            vm.prank(alice);
            (bool sent,) = address(usdt).call(abi.encodeCall(IERC20.transfer, (carol, 1)));
            assertFalse(sent);
        }

        vm.startPrank(safe);
        usdt.forceApprove(address(vault), amount);
        vault.returnCapital(amount);
        vault.fulfillWithdraw(id, interest);
        vault.payIntroducerFee(id, fee);
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), amount + interest + extra);
        assertEq(usdt.balanceOf(carol), fee);
        assertEq(usdt.balanceOf(address(vault)), 0);
        (, uint256 owed, uint256 pots,, uint256 deployed) = vault.vaultState();
        assertEq(owed + pots + deployed, 0);
    }
}

/// @notice Skipped unless SEPOLIA_RPC_URL is set. Runs on the team's `TestTether`, deployed on the fork the way
/// DeployTestTether does.
contract DeosxVaultSepoliaForkTest is ForkFlow {
    function test_Fork_Sepolia_TestTetherDepositPotsOutReturnPayoutFee() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 11155111);
        TestTether token = new TestTether();
        _deployVault(address(token));

        token.mint(alice, 100_000e6);
        token.mint(safe, 25_000e6);
        _runFlow(100_000e6, false);
    }
}

/// @notice Skipped unless MAINNET_RPC_URL is set.
contract DeosxVaultMainnetForkTest is ForkFlow {
    function test_Fork_Mainnet_DepositPotsOutReturnPayoutFee() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 1);
        _deployVault(address(0));

        deal(address(usdt), alice, 250_000e6);
        deal(address(usdt), safe, 62_500e6);
        _runFlow(250_000e6, true);
    }
}
