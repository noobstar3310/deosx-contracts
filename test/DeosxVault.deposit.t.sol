// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DeosxVault} from "../src/DeosxVault.sol";
import {TrancheToken} from "../src/TrancheToken.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

contract DeosxVaultDepositTest is VaultTestBase {
    function test_Deposit_IntoT1_MintsLpOneToOne() public {
        uint256[3] memory pieces = [uint256(500_000e6), 0, 0];
        usdt.mint(alice, 500_000e6);
        _approve(alice, 500_000e6);
        vm.expectEmit(address(vault));
        emit DeosxVault.Deposited(alice, 500_000e6, pieces);
        vm.prank(alice);
        vault.deposit(500_000e6, ANY_SPLIT);

        assertEq(_lp(0).balanceOf(alice), 500_000e6);
        assertEq(vault.capitalOf(alice), 500_000e6);
        assertEq(vault.available(alice, 0), 500_000e6);
        assertEq(usdt.balanceOf(address(vault)), 500_000e6);
        DeosxVault.TrancheView memory t = vault.trancheInfo(0);
        assertEq(t.taken, 500_000e6);
        assertEq(t.capital, 500_000e6);
        assertEq(t.room, T1_SIZE - 500_000e6);
    }

    /// One deposit that crosses two boundaries is split T1 → T2 → T3, each piece its own position and LP.
    function test_Deposit_WaterfallAcrossAllThree() public {
        _deposit(bob, 1_900_000e6);
        uint256[3] memory expected = [uint256(100_000e6), 3_000_000e6, 400_000e6];
        uint256[3] memory preview = vault.previewDeposit(3_500_000e6);
        for (uint256 i; i < 3; ++i) {
            assertEq(preview[i], expected[i]);
        }

        _deposit(alice, 3_500_000e6);
        for (uint256 i; i < 3; ++i) {
            assertEq(_lp(i).balanceOf(alice), expected[i]);
            assertEq(vault.available(alice, i), expected[i]);
            DeosxVault.PositionView[] memory p = vault.positionsOf(alice, i);
            assertEq(p.length, 1);
            assertEq(p[0].amount, expected[i]);
            assertEq(p[0].depositedAt, T0);
        }
        assertEq(vault.trancheInfo(0).room, 0);
        assertEq(vault.trancheInfo(1).room, 0);
        assertEq(vault.trancheInfo(2).room, T3_SIZE - 400_000e6);
        assertEq(vault.capitalOf(alice), 3_500_000e6);
    }

    function test_Deposit_FillsEveryTrancheExactly_ThenRefuses() public {
        _deposit(alice, T1_SIZE + T2_SIZE + T3_SIZE);
        for (uint256 i; i < 3; ++i) {
            assertEq(vault.trancheInfo(i).room, 0);
        }
        usdt.mint(bob, OPENING);
        _approve(bob, OPENING);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.ExceedsCapacity.selector, 0));
        vault.deposit(OPENING, ANY_SPLIT);
    }

    function test_Deposit_RevertWhen_MoreThanRoomLeft() public {
        _deposit(bob, T1_SIZE + T2_SIZE + T3_SIZE - 50_000e6);
        usdt.mint(alice, OPENING);
        _approve(alice, OPENING);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.ExceedsCapacity.selector, 50_000e6));
        vault.deposit(OPENING, ANY_SPLIT);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.ExceedsCapacity.selector, 50_000e6));
        vault.previewDeposit(OPENING);
    }

    function test_Deposit_OpeningMinimum_ThenTopUpMinimum() public {
        usdt.mint(alice, OPENING);
        _approve(alice, OPENING - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.BelowMinimum.selector, OPENING - 1, OPENING));
        vault.deposit(OPENING - 1, ANY_SPLIT);

        _deposit(alice, OPENING);
        usdt.mint(alice, TOPUP);
        _approve(alice, TOPUP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.BelowMinimum.selector, TOPUP - 1, TOPUP));
        vault.deposit(TOPUP - 1, ANY_SPLIT);

        _deposit(alice, TOPUP);
        assertEq(vault.capitalOf(alice), OPENING + TOPUP);
    }

    /// A top-up opens a new position, so each part keeps its own clock.
    function test_Deposit_TopUpOpensNewPosition() public {
        _deposit(alice, OPENING);
        vm.warp(T0 + 10 days);
        _deposit(alice, TOPUP);
        DeosxVault.PositionView[] memory p = vault.positionsOf(alice, 0);
        assertEq(p.length, 2);
        assertEq(p[0].amount, OPENING);
        assertEq(p[0].depositedAt, T0);
        assertEq(p[0].heldFor, 10 days);
        assertEq(p[1].amount, TOPUP);
        assertEq(p[1].depositedAt, T0 + 10 days);
        assertEq(p[1].heldFor, 0);
    }

    function test_PositionsOf_TierFollowsHoldingTime() public {
        _deposit(alice, OPENING);
        assertEq(vault.positionsOf(alice, 0)[0].tierBps, 0);
        vm.warp(T0 + HALF - 1);
        assertEq(vault.positionsOf(alice, 0)[0].tierBps, 0);
        vm.warp(T0 + HALF);
        assertEq(vault.positionsOf(alice, 0)[0].tierBps, 5_000);
        vm.warp(T0 + FULL - 1);
        assertEq(vault.positionsOf(alice, 0)[0].tierBps, 5_000);
        vm.warp(T0 + FULL);
        assertEq(vault.positionsOf(alice, 0)[0].tierBps, 10_000);
        vm.warp(T0 + 3 * 365 days);
        assertEq(vault.positionsOf(alice, 0)[0].tierBps, 10_000);
    }

    /// The minimum is judged on what arrived, so a USDT fee can't credit more than the vault received.
    function test_Deposit_CreditsWhatArrives_WhenFeeOn() public {
        usdt.setFee(10, 1_000e6); // 0.1%, capped at 1,000
        uint256 sent = 200_000e6;
        uint256 arrived = sent - 200e6;
        _deposit(alice, sent);
        assertEq(vault.capitalOf(alice), arrived);
        assertEq(_lp(0).balanceOf(alice), arrived);
        assertEq(usdt.balanceOf(address(vault)), arrived);
    }

    function test_Deposit_RevertWhen_FeeTakesItBelowMinimum() public {
        usdt.setFee(10, 1_000e6);
        usdt.mint(alice, OPENING);
        _approve(alice, OPENING);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.BelowMinimum.selector, OPENING - 100e6, OPENING));
        vault.deposit(OPENING, ANY_SPLIT);
    }

    function test_Deposit_RevertWhen_NotWhitelisted() public {
        usdt.mint(otc, OPENING);
        _approve(otc, OPENING);
        vm.prank(otc);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.NotWhitelisted.selector, otc));
        vault.deposit(OPENING, ANY_SPLIT);
    }

    function test_Deposit_RevertWhen_Zero() public {
        vm.prank(alice);
        vm.expectRevert(DeosxVault.ZeroAmount.selector);
        vault.deposit(0, ANY_SPLIT);
    }

    function test_Deposit_RevertWhen_Paused() public {
        vm.prank(safe);
        vault.pause();
        usdt.mint(alice, OPENING);
        _approve(alice, OPENING);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(OPENING, ANY_SPLIT);
    }

    /// Removing a wallet from the whitelist stops new deposits but never traps what it holds.
    function test_Dewhitelisted_CanStillRequestWithdraw() public {
        _deposit(alice, OPENING);
        vm.prank(operator);
        vault.setWhitelisted(alice, false);
        uint256 id = _request(alice, 0, OPENING);
        assertEq(vault.getRequest(id).amount, OPENING);
    }

    function test_LpToken_NotTransferable() public {
        _deposit(alice, OPENING);
        IERC20Metadata lp = _lp(0);
        vm.prank(alice);
        vm.expectRevert(TrancheToken.SharesNonTransferable.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        lp.transfer(bob, 1);
    }

    /// No allowance can ever be set, so `transferFrom` stops at OpenZeppelin's allowance check; a 0 amount passes it
    /// and is stopped by the transfer block.
    function test_LpToken_TransferFromReverts() public {
        _deposit(alice, OPENING);
        IERC20Metadata lp = _lp(0);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        lp.transferFrom(alice, bob, 1);
        vm.expectRevert(TrancheToken.SharesNonTransferable.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        lp.transferFrom(alice, bob, 0);
        vm.stopPrank();
    }

    /// Only the vault that deployed the token can mint or burn it.
    function test_LpToken_OnlyVaultMintsAndBurns() public {
        _deposit(alice, OPENING);
        TrancheToken lp = TrancheToken(address(_lp(0)));
        vm.startPrank(safe);
        vm.expectRevert(TrancheToken.NotVault.selector);
        lp.mint(safe, 1);
        vm.expectRevert(TrancheToken.NotVault.selector);
        lp.burn(alice, 1);
        vm.stopPrank();
    }

    function testFuzz_Deposit_WaterfallMatchesRoom(uint256 first, uint256 second) public {
        uint256 total = T1_SIZE + T2_SIZE + T3_SIZE;
        first = bound(first, OPENING, total - OPENING);
        second = bound(second, OPENING, total - first);
        _deposit(bob, first);
        _deposit(alice, second);

        uint256 sumLp;
        uint256 sumTaken;
        for (uint256 i; i < 3; ++i) {
            DeosxVault.TrancheView memory t = vault.trancheInfo(i);
            assertEq(t.capital, _lp(i).totalSupply());
            assertEq(t.taken, t.capital);
            assertLe(t.taken, t.size);
            // A later tranche only fills once every earlier one is full.
            if (i > 0 && t.taken > 0) assertEq(vault.trancheInfo(i - 1).room, 0);
            sumLp += _lp(i).balanceOf(alice);
            sumTaken += t.taken;
        }
        assertEq(sumLp, second);
        assertEq(sumTaken, first + second);
        assertEq(usdt.balanceOf(address(vault)), first + second);
    }
}
