// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeosxVault} from "../src/DeosxVault.sol";
import {TestTether} from "../src/testnet/TestTether.sol";

contract TestTetherTest is Test {
    using SafeERC20 for IERC20;

    TestTether internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new TestTether();
    }

    function test_Metadata() public view {
        assertEq(token.name(), "DEOS-X Test Tether USD");
        assertEq(token.symbol(), "USDT");
        assertEq(token.decimals(), 6);
    }

    function test_Mint_AnyoneUpToMax() public {
        vm.expectEmit(address(token));
        emit TestTether.Transfer(address(0), alice, 20_000_000e6);
        vm.prank(bob);
        token.mint(alice, 20_000_000e6);
        assertEq(token.balanceOf(alice), 20_000_000e6);
        assertEq(token.totalSupply(), 20_000_000e6);
    }

    function test_Mint_RevertWhen_ZeroOrAboveMax() public {
        vm.expectRevert(TestTether.ZeroAmount.selector);
        token.mint(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(TestTether.AboveMaxMint.selector, 20_000_000e6 + 1, 20_000_000e6));
        token.mint(alice, 20_000_000e6 + 1);
    }

    /// Like USDT, the writes succeed but return no data (so a caller decoding a bool can't use them); SafeERC20 works.
    function test_WritesReturnNothing() public {
        token.mint(alice, 100e6);
        vm.prank(alice);
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transfer, (bob, 1e6)));
        assertTrue(ok);
        assertEq(data.length, 0);
        vm.prank(alice);
        (ok, data) = address(token).call(abi.encodeCall(IERC20.approve, (bob, 1e6)));
        assertTrue(ok);
        assertEq(data.length, 0);

        vm.prank(alice);
        IERC20(address(token)).safeTransfer(bob, 1e6);
        assertEq(token.balanceOf(bob), 2e6);
    }

    function test_Approve_RejectsNonZeroToNonZero() public {
        vm.startPrank(alice);
        token.approve(bob, 5e6);
        vm.expectRevert(TestTether.ApproveFromNonZero.selector);
        token.approve(bob, 6e6);
        token.approve(bob, 0);
        token.approve(bob, 6e6);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 6e6);
    }

    function test_TransferFrom_SpendsAllowance() public {
        token.mint(alice, 10e6);
        vm.prank(alice);
        token.approve(bob, 4e6);
        vm.prank(bob);
        token.transferFrom(alice, bob, 3e6);
        assertEq(token.balanceOf(bob), 3e6);
        assertEq(token.allowance(alice, bob), 1e6);
        vm.prank(bob);
        vm.expectRevert(TestTether.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 2e6);
    }

    function test_TransferFrom_InfiniteAllowanceStays() public {
        token.mint(alice, 10e6);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 3e6);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_Transfer_RevertWhen_ShortBalance() public {
        token.mint(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(TestTether.InsufficientBalance.selector);
        token.transfer(bob, 1e6 + 1);
    }

    /// The vault runs on it end to end: deposit, payout.
    function test_WorksWithTheVault() public {
        address safe = makeAddr("safe");
        DeosxVault vault = new DeosxVault(
            IERC20Metadata(address(token)),
            safe,
            [uint256(2_000_000e6), 3_000_000e6, 15_000_000e6],
            60 minutes,
            90 minutes,
            100_000e6,
            10_000e6
        );
        vm.prank(safe);
        vault.setWhitelisted(alice, true);
        token.mint(alice, 2_500_000e6);
        vm.startPrank(alice);
        token.approve(address(vault), 2_500_000e6);
        vault.deposit(2_500_000e6, [uint256(0), 0, 0]);
        uint256 id = vault.requestWithdraw(1, 500_000e6);
        vm.stopPrank();
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        assertEq(token.balanceOf(alice), 500_000e6);
    }
}
