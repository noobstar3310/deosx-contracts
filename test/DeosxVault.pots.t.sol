// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeosxVault} from "../src/DeosxVault.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

contract DeosxVaultPotsTest is VaultTestBase {
    function test_FundInterest_IntoOneTranchesPot() public {
        _fundSafe(30_000e6);
        vm.expectEmit(address(vault));
        emit DeosxVault.InterestFunded(1, 30_000e6);
        vm.prank(safe);
        vault.fundInterest(1, 30_000e6);

        assertEq(vault.trancheInfo(0).interestPot, 0);
        assertEq(vault.trancheInfo(1).interestPot, 30_000e6);
        assertEq(vault.trancheInfo(2).interestPot, 0);
        assertEq(vault.totalInterestPot(), 30_000e6);
        assertEq(usdt.balanceOf(address(vault)), 30_000e6);
    }

    function test_FundInterest_CreditsWhatArrives_WhenFeeOn() public {
        usdt.setFee(10, 1_000e6);
        _fundInterest(0, 100_000e6);
        assertEq(vault.trancheInfo(0).interestPot, 100_000e6 - 100e6);
        assertEq(vault.totalInterestPot(), 100_000e6 - 100e6);
    }

    function test_FundInterest_RevertWhen_ZeroOrUnknownTranche() public {
        vm.startPrank(safe);
        vm.expectRevert(DeosxVault.ZeroAmount.selector);
        vault.fundInterest(0, 0);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.UnknownTranche.selector, 3));
        vault.fundInterest(3, 1);
        vm.stopPrank();
    }

    function test_WithdrawInterest_BackToSafe() public {
        _fundInterest(2, 50_000e6);
        vm.expectEmit(address(vault));
        emit DeosxVault.InterestWithdrawn(2, 20_000e6);
        vm.prank(safe);
        vault.withdrawInterest(2, 20_000e6);
        assertEq(vault.trancheInfo(2).interestPot, 30_000e6);
        assertEq(vault.totalInterestPot(), 30_000e6);
        assertEq(usdt.balanceOf(safe), 20_000e6);
    }

    /// One tranche's pot can't be drawn from another's, nor from capital.
    function test_WithdrawInterest_RevertWhen_MoreThanThatPot() public {
        _deposit(alice, OPENING);
        _fundInterest(0, 10_000e6);
        _fundInterest(1, 10_000e6);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InsufficientInterest.selector, 10_000e6, 10_000e6 + 1));
        vault.withdrawInterest(0, 10_000e6 + 1);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InsufficientInterest.selector, 0, 1));
        vault.withdrawInterest(2, 1);
        vm.expectRevert(DeosxVault.ZeroAmount.selector);
        vault.withdrawInterest(0, 0);
        vm.stopPrank();
    }

    function test_TransferOut_CapitalOnly() public {
        _deposit(alice, 1_000_000e6);
        _fundInterest(0, 50_000e6);

        vm.expectEmit(address(vault));
        emit DeosxVault.CapitalTransferredOut(otc, 1_000_000e6);
        vm.prank(safe);
        vault.transferOut(otc, 1_000_000e6);
        assertEq(usdt.balanceOf(otc), 1_000_000e6);
        assertEq(vault.deployedCapital(), 1_000_000e6);

        // What is left is the interest pot, and it can't be sent out as capital.
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InsufficientCapital.selector, 0, 1));
        vault.transferOut(otc, 1);
        assertEq(vault.trancheInfo(0).interestPot, 50_000e6);
    }

    function test_TransferOut_RevertWhen_BadRecipientOrZero() public {
        _deposit(alice, OPENING);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InvalidRecipient.selector, address(0)));
        vault.transferOut(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InvalidRecipient.selector, address(vault)));
        vault.transferOut(address(vault), 1);
        vm.expectRevert(DeosxVault.ZeroAmount.selector);
        vault.transferOut(otc, 0);
        vm.stopPrank();
    }

    function test_ReturnCapital_ReducesDeployed() public {
        _deposit(alice, 1_000_000e6);
        vm.prank(safe);
        vault.transferOut(otc, 600_000e6);

        _fundSafe(400_000e6);
        vm.expectEmit(address(vault));
        emit DeosxVault.CapitalReturned(400_000e6);
        vm.prank(safe);
        vault.returnCapital(400_000e6);
        assertEq(vault.deployedCapital(), 200_000e6);
        assertEq(usdt.balanceOf(address(vault)), 800_000e6);
    }

    function test_ReturnCapital_RevertWhen_MoreThanDeployed() public {
        _deposit(alice, OPENING);
        vm.prank(safe);
        vault.transferOut(otc, 10_000e6);
        _fundSafe(10_000e6 + 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.ExceedsDeployed.selector, 10_000e6, 10_000e6 + 1));
        vault.returnCapital(10_000e6 + 1);

        vm.prank(safe);
        vm.expectRevert(DeosxVault.ZeroAmount.selector);
        vault.returnCapital(0);
    }

    function test_VaultState_SplitsCapitalAndInterest() public {
        _deposit(alice, 2_500_000e6);
        _fundInterest(0, 40_000e6);
        _fundInterest(1, 10_000e6);
        vm.prank(safe);
        vault.transferOut(otc, 1_000_000e6);

        (uint256 inVault, uint256 owed, uint256 pots, uint256 cash, uint256 deployed) = vault.vaultState();
        assertEq(inVault, 1_550_000e6);
        assertEq(owed, 2_500_000e6);
        assertEq(pots, 50_000e6);
        assertEq(cash, 1_500_000e6);
        assertEq(deployed, 1_000_000e6);
        // What the vault owes in capital is held or deployed.
        assertEq(cash + deployed, owed);
    }

    /// If the vault ever holds less than its pots (Tether destroying or seizing funds), capital cash reads 0 instead
    /// of panicking, and capital payouts and `transferOut` revert with `InsufficientCapital(0, needed)`.
    function test_VaultState_CapitalCashSaturatesAtZero() public {
        _deposit(alice, OPENING);
        _fundInterest(0, 50_000e6);
        uint256 id = _request(alice, 0, OPENING);
        deal(address(usdt), address(vault), 40_000e6);

        (uint256 inVault, uint256 owed, uint256 pots, uint256 cash,) = vault.vaultState();
        assertEq(inVault, 40_000e6);
        assertEq(owed, OPENING);
        assertEq(pots, 50_000e6);
        assertEq(cash, 0);

        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InsufficientCapital.selector, 0, 1));
        vault.transferOut(otc, 1);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InsufficientCapital.selector, 0, OPENING));
        vault.fulfillWithdraw(id, 0);
        vm.stopPrank();
    }
}
