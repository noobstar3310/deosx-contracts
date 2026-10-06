// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {DeosxVault} from "../src/DeosxVault.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

contract DeosxVaultWithdrawTest is VaultTestBase {
    // ----- requests -----

    function test_Request_RecordsSnapshotAndReserves() public {
        _deposit(alice, 300_000e6);
        vm.warp(T0 + 95 days);

        vm.expectEmit(address(vault));
        emit DeosxVault.WithdrawRequested(1, alice, 0, 120_000e6, 0, 0, 120_000e6);
        uint256 id = _request(alice, 0, 120_000e6);

        assertEq(id, 1);
        assertEq(vault.requestCount(), 1);
        DeosxVault.Request memory r = vault.getRequest(id);
        assertEq(r.owner, alice);
        assertEq(r.tranche, 0);
        assertEq(r.requestedAt, T0 + 95 days);
        assertEq(uint8(r.status), uint8(DeosxVault.RequestStatus.Pending));
        assertEq(uint8(r.feeStatus), uint8(DeosxVault.FeeStatus.None));
        assertEq(r.introducer, carol);
        assertEq(r.amount, 120_000e6);
        assertEq(r.heldFull, 120_000e6);
        assertEq(vault.reserved(alice, 0), 120_000e6);
        assertEq(vault.available(alice, 0), 180_000e6);
        assertEq(vault.pendingRequests().length, 1);
        // Nothing moves until the Safe pays.
        assertEq(_lp(0).balanceOf(alice), 300_000e6);
    }

    /// A request spanning positions of different ages splits by tier, oldest first.
    function test_Request_SplitsAcrossTiersOldestFirst() public {
        _deposit(alice, 100_000e6); // T0
        vm.warp(T0 + 30 days);
        _deposit(alice, 50_000e6); // T0 + 30d
        vm.warp(T0 + 70 days);
        _deposit(alice, 20_000e6); // T0 + 70d
        vm.warp(T0 + 95 days);
        // held: 95d (full), 65d (half), 25d (none)
        uint256 id = _request(alice, 0, 160_000e6);
        DeosxVault.Request memory r = vault.getRequest(id);
        assertEq(r.heldFull, 100_000e6);
        assertEq(r.heldHalf, 50_000e6);
        assertEq(r.heldUnderHalf, 10_000e6);
    }

    /// A wallet has at most one pending request across all tranches: a second one reverts naming the open one, in
    /// the same tranche and in another.
    function test_Request_RevertWhen_OneAlreadyPending() public {
        _deposit(alice, T1_SIZE + 500_000e6); // 2M in T1, 500k in T2
        uint256 id = _request(alice, 0, 100_000e6);
        assertEq(vault.openRequestOf(alice), id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.RequestPending.selector, id));
        vault.requestWithdraw(0, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.RequestPending.selector, id));
        vault.requestWithdraw(1, 100_000e6);
        assertEq(vault.pendingRequests().length, 1);
        assertEq(vault.reserved(alice, 1), 0);
    }

    /// Another wallet's open request doesn't stop this one.
    function test_Request_OneOpenPerWallet_NotPerVault() public {
        _deposit(alice, OPENING);
        _deposit(bob, OPENING);
        uint256 a = _request(alice, 0, OPENING);
        uint256 b = _request(bob, 0, OPENING);
        assertEq(vault.openRequestOf(alice), a);
        assertEq(vault.openRequestOf(bob), b);
        assertEq(vault.pendingRequests().length, 2);
    }

    /// Cancelling clears the open request, and a new one (in any tranche) works.
    function test_Request_AfterCancel_NewRequestWorks() public {
        _deposit(alice, T1_SIZE + 500_000e6);
        uint256 first = _request(alice, 0, 100_000e6);
        vm.prank(alice);
        vault.cancelWithdraw(first);
        assertEq(vault.openRequestOf(alice), 0);
        assertEq(vault.reserved(alice, 0), 0);

        uint256 second = _request(alice, 1, 200_000e6);
        assertEq(second, first + 1);
        assertEq(vault.openRequestOf(alice), second);
        assertEq(vault.reserved(alice, 1), 200_000e6);
    }

    /// Paying out clears the open request, and a new one works.
    function test_Request_AfterPayout_NewRequestWorks() public {
        _deposit(alice, 300_000e6);
        uint256 first = _request(alice, 0, 100_000e6);
        vm.prank(safe);
        vault.fulfillWithdraw(first, 0);
        assertEq(vault.openRequestOf(alice), 0);

        uint256 second = _request(alice, 0, 200_000e6);
        assertEq(vault.openRequestOf(alice), second);
        assertEq(vault.available(alice, 0), 0);
    }

    /// There is no request minimum: 1 unit can be requested, and a request can leave 1 unit free.
    function test_Request_AnyAmount_NoMinimum() public {
        _deposit(alice, OPENING);
        uint256 one = _request(alice, 0, 1);
        assertEq(vault.getRequest(one).amount, 1);
        assertEq(vault.available(alice, 0), OPENING - 1);
        vm.prank(alice);
        vault.cancelWithdraw(one);

        uint256 most = _request(alice, 0, OPENING - 1);
        assertEq(vault.available(alice, 0), 1);
        vm.prank(safe);
        vault.fulfillWithdraw(most, 0);
        uint256 last = _request(alice, 0, 1);
        vm.prank(safe);
        vault.fulfillWithdraw(last, 0);
        assertEq(vault.capitalOf(alice), 0);
        assertEq(usdt.balanceOf(alice), OPENING);
    }

    /// Any amount from 1 up to what is free works and reserves exactly that.
    function testFuzz_Request_AnyAmountUpToFree(uint256 deposit, uint256 amount) public {
        deposit = bound(deposit, OPENING, 1_000_000e6);
        _deposit(alice, deposit);
        amount = bound(amount, 1, deposit);
        uint256 id = _request(alice, 0, amount);
        assertEq(vault.openRequestOf(alice), id);
        assertEq(vault.reserved(alice, 0), amount);
        assertEq(vault.available(alice, 0), deposit - amount);
    }

    /// Each request's split is measured at its own `requestedAt`, at exactly the tier boundaries. One request at a
    /// time: each is cancelled before the next, and a cancelled request keeps the split it was made with.
    function test_Request_SnapshotAtTierBoundaries() public {
        _deposit(alice, 100_000e6); // T0
        uint64[4] memory at = [T0 + HALF - 1, T0 + HALF, T0 + FULL - 1, T0 + FULL];
        uint256[4] memory ids;
        for (uint256 i; i < 4; ++i) {
            vm.warp(at[i]);
            ids[i] = _request(alice, 0, 25_000e6);
            if (i < 3) {
                vm.prank(alice);
                vault.cancelWithdraw(ids[i]);
            }
        }
        vm.warp(T0 + 400 days); // the split doesn't drift with time
        DeosxVault.Request memory r = vault.getRequest(ids[0]);
        assertEq(r.heldUnderHalf, 25_000e6);
        r = vault.getRequest(ids[1]);
        assertEq(r.heldHalf, 25_000e6);
        r = vault.getRequest(ids[2]);
        assertEq(r.heldHalf, 25_000e6);
        r = vault.getRequest(ids[3]);
        assertEq(r.heldFull, 25_000e6);
        assertEq(r.heldHalf + r.heldUnderHalf, 0);
    }

    function test_Request_RevertWhen_MoreThanAvailable() public {
        _deposit(alice, OPENING);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.ExceedsAvailable.selector, OPENING, OPENING + 1));
        vault.requestWithdraw(0, OPENING + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.ExceedsAvailable.selector, 0, 1));
        vault.requestWithdraw(1, 1);
    }

    function test_Request_RevertWhen_ZeroUnknownOrPaused() public {
        _deposit(alice, OPENING);
        vm.startPrank(alice);
        vm.expectRevert(DeosxVault.ZeroAmount.selector);
        vault.requestWithdraw(0, 0);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.UnknownTranche.selector, 3));
        vault.requestWithdraw(3, 1);
        vm.stopPrank();
        vm.prank(safe);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.requestWithdraw(0, 1);
    }

    /// The introducer is taken when the request is made; a later change doesn't redirect a fee.
    function test_Request_IntroducerFixedAtRequest() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        vm.prank(operator);
        vault.setIntroducer(alice, otc);
        assertEq(vault.getRequest(id).introducer, carol);
    }

    // ----- cancel -----

    function test_Cancel_FreesReserve() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        vm.expectEmit(address(vault));
        emit DeosxVault.WithdrawCancelled(id, alice);
        vm.prank(alice);
        vault.cancelWithdraw(id);
        assertEq(uint8(vault.getRequest(id).status), uint8(DeosxVault.RequestStatus.Cancelled));
        assertEq(vault.reserved(alice, 0), 0);
        assertEq(vault.available(alice, 0), OPENING);
        assertEq(vault.pendingRequests().length, 0);
        assertEq(vault.openRequestOf(alice), 0);
    }

    function test_Cancel_WorksWhilePaused() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        vm.prank(safe);
        vault.pause();
        vm.prank(alice);
        vault.cancelWithdraw(id);
    }

    function test_Cancel_RevertWhen_NotOwnerUnknownOrNotPending() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        vm.prank(bob);
        vm.expectRevert(DeosxVault.NotRequestOwner.selector);
        vault.cancelWithdraw(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.UnknownRequest.selector, 2));
        vault.cancelWithdraw(2);
        vm.prank(alice);
        vault.cancelWithdraw(id);
        vm.prank(alice);
        vm.expectRevert(DeosxVault.NotPending.selector);
        vault.cancelWithdraw(id);
    }

    // ----- fulfil -----

    function test_Fulfill_BurnsLpPaysCapitalPlusInterest() public {
        _deposit(alice, 1_000_000e6);
        _fundInterest(0, 200_000e6);
        vm.warp(T0 + 365 days);
        uint256 id = _request(alice, 0, 400_000e6);

        vm.expectEmit(address(vault));
        emit DeosxVault.WithdrawFulfilled(id, alice, 0, 400_000e6, 60_000e6);
        vm.expectEmit(address(vault));
        emit DeosxVault.IntroducerFeeDue(id, carol);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 60_000e6);

        assertEq(usdt.balanceOf(alice), 460_000e6);
        assertEq(_lp(0).balanceOf(alice), 600_000e6);
        assertEq(vault.capitalOf(alice), 600_000e6);
        assertEq(vault.reserved(alice, 0), 0);
        assertEq(vault.available(alice, 0), 600_000e6);
        DeosxVault.TrancheView memory t = vault.trancheInfo(0);
        assertEq(t.capital, 600_000e6);
        assertEq(t.interestPot, 140_000e6);
        assertEq(vault.totalInterestPot(), 140_000e6);
        DeosxVault.Request memory r = vault.getRequest(id);
        assertEq(uint8(r.status), uint8(DeosxVault.RequestStatus.Paid));
        assertEq(uint8(r.feeStatus), uint8(DeosxVault.FeeStatus.Due));
        assertEq(r.interest, 60_000e6);
        assertEq(vault.pendingRequests().length, 0);
        assertEq(vault.openRequestOf(alice), 0);
        assertEq(vault.feesDue().length, 1);
        assertEq(vault.feesDue()[0], id);
        DeosxVault.PositionView[] memory p = vault.positionsOf(alice, 0);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 600_000e6);
        assertEq(p[0].depositedAt, T0);
    }

    function test_Fulfill_ZeroInterest_NeedsNoPot() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        assertEq(usdt.balanceOf(alice), OPENING);
        assertEq(_lp(0).totalSupply(), 0);
        assertEq(vault.capitalOf(alice), 0);
    }

    /// Full exit then a new deposit counts as an opening deposit again.
    function test_Fulfill_FullExit_NextDepositIsOpening() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        usdt.mint(alice, TOPUP);
        _approve(alice, TOPUP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.BelowMinimum.selector, TOPUP, OPENING));
        vault.deposit(TOPUP, ANY_SPLIT);
    }

    /// Paying out consumes positions oldest first, leaving the younger ones with their own dates.
    function test_Fulfill_ConsumesOldestPositionsFirst() public {
        _deposit(alice, 100_000e6);
        vm.warp(T0 + 10 days);
        _deposit(alice, 20_000e6);
        vm.warp(T0 + 20 days);
        _deposit(alice, 30_000e6);

        uint256 id = _request(alice, 0, 110_000e6);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        DeosxVault.PositionView[] memory p = vault.positionsOf(alice, 0);
        assertEq(p.length, 2);
        assertEq(p[0].amount, 10_000e6);
        assertEq(p[0].depositedAt, T0 + 10 days);
        assertEq(p[1].amount, 30_000e6);
        assertEq(p[1].depositedAt, T0 + 20 days);
    }

    /// A position paid out exactly is gone from the list, not left behind at zero.
    function test_Fulfill_ExactPositionLeavesTheList() public {
        _deposit(alice, 100_000e6);
        vm.warp(T0 + 1 days);
        _deposit(alice, 20_000e6);
        uint256 id = _request(alice, 0, 100_000e6);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        DeosxVault.PositionView[] memory p = vault.positionsOf(alice, 0);
        assertEq(p.length, 1);
        assertEq(p[0].amount, 20_000e6);
        assertEq(p[0].depositedAt, T0 + 1 days);
    }

    /// The split a request is paid on is measured at its `requestedAt`, however late the payout: units 30 days old
    /// when requested stay under the 50% tier even when paid on day 200.
    function test_Fulfill_PaidSplitMeasuredAtRequest() public {
        _deposit(alice, OPENING); // T0
        vm.warp(T0 + 30 days);
        uint256 id = _request(alice, 0, OPENING);
        vm.warp(T0 + 200 days);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        DeosxVault.Request memory r = vault.getRequest(id);
        assertEq(r.heldUnderHalf, OPENING);
        assertEq(r.heldHalf + r.heldFull, 0);
    }

    /// A fee becomes due for the introducer recorded on the request and is paid to it, even after the operator
    /// changes or clears the wallet's introducer.
    function test_Fulfill_FeeGoesToIntroducerAtRequest() public {
        _deposit(alice, 200_000e6);
        _fundInterest(0, 10_000e6);
        uint256 first = _request(alice, 0, 100_000e6);

        vm.prank(operator);
        vault.setIntroducer(alice, otc);
        vm.expectEmit(address(vault));
        emit DeosxVault.WithdrawFulfilled(first, alice, 0, 100_000e6, 0);
        vm.expectEmit(address(vault));
        emit DeosxVault.IntroducerFeeDue(first, carol);
        vm.prank(safe);
        vault.fulfillWithdraw(first, 0);

        uint256 second = _request(alice, 0, 100_000e6);
        vm.prank(operator);
        vault.setIntroducer(alice, address(0));
        vm.expectEmit(address(vault));
        emit DeosxVault.WithdrawFulfilled(second, alice, 0, 100_000e6, 0);
        vm.expectEmit(address(vault));
        emit DeosxVault.IntroducerFeeDue(second, otc);
        vm.prank(safe);
        vault.fulfillWithdraw(second, 0);
        assertEq(vault.feesDue().length, 2);

        vm.startPrank(safe);
        vault.payIntroducerFee(first, 1_000e6);
        vault.payIntroducerFee(second, 2_000e6);
        vm.stopPrank();
        assertEq(usdt.balanceOf(carol), 1_000e6);
        assertEq(usdt.balanceOf(otc), 2_000e6);
    }

    function test_Fulfill_RevertWhen_InterestAbovePot() public {
        _deposit(alice, OPENING);
        _fundInterest(0, 1_000e6);
        _fundInterest(1, 50_000e6); // another tranche's pot doesn't help
        uint256 id = _request(alice, 0, OPENING);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InsufficientInterest.selector, 1_000e6, 1_000e6 + 1));
        vault.fulfillWithdraw(id, 1_000e6 + 1);
    }

    /// Deployed capital must come back before it can be paid; the interest pots can't cover capital.
    function test_Fulfill_RevertWhen_CapitalDeployed() public {
        _deposit(alice, OPENING);
        _fundInterest(0, 500_000e6);
        vm.prank(safe);
        vault.transferOut(otc, 60_000e6);
        uint256 id = _request(alice, 0, OPENING);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InsufficientCapital.selector, 40_000e6, OPENING));
        vault.fulfillWithdraw(id, 0);

        _fundSafe(60_000e6);
        vm.prank(safe);
        vault.returnCapital(60_000e6);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        assertEq(usdt.balanceOf(alice), OPENING);
    }

    function test_Fulfill_RevertWhen_UnknownOrNotPending() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, 50_000e6);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.UnknownRequest.selector, 9));
        vault.fulfillWithdraw(9, 0);
        vault.fulfillWithdraw(id, 0);
        vm.expectRevert(DeosxVault.NotPending.selector);
        vault.fulfillWithdraw(id, 0);
        vm.stopPrank();

        uint256 cancelled = _request(alice, 0, 50_000e6);
        vm.prank(alice);
        vault.cancelWithdraw(cancelled);
        vm.prank(safe);
        vm.expectRevert(DeosxVault.NotPending.selector);
        vault.fulfillWithdraw(cancelled, 0);
    }

    function test_Fulfill_WorksWhilePaused() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        vm.startPrank(safe);
        vault.pause();
        vault.fulfillWithdraw(id, 0);
        vm.stopPrank();
        assertEq(usdt.balanceOf(alice), OPENING);
    }

    /// With USDT's fee on, the investor receives the amount less the token's fee; the vault's books stay exact.
    function test_Fulfill_WhenFeeOn_BooksStayExact() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        usdt.setFee(10, 1_000e6);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        assertEq(usdt.balanceOf(alice), OPENING - 100e6);
        assertEq(usdt.balanceOf(address(vault)), 0);
        assertEq(vault.trancheInfo(0).capital, 0);
    }

    // ----- tranche reopening -----

    function test_T1_NeverReopens() public {
        _deposit(alice, T1_SIZE);
        uint256 id = _request(alice, 0, 500_000e6);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        DeosxVault.TrancheView memory t = vault.trancheInfo(0);
        assertEq(t.capital, T1_SIZE - 500_000e6);
        assertEq(t.room, 0);
        _deposit(bob, OPENING);
        assertEq(_lp(1).balanceOf(bob), OPENING);
    }

    function test_T2_NeverReopens() public {
        _deposit(alice, T1_SIZE + T2_SIZE);
        uint256 id = _request(alice, 1, 500_000e6);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        assertEq(vault.trancheInfo(1).room, 0);
        _deposit(bob, OPENING);
        assertEq(_lp(2).balanceOf(bob), OPENING);
    }

    /// T3's room comes back when its capital is paid out, first come first served.
    function test_T3_ReopensWhenCapitalLeaves() public {
        _deposit(alice, T1_SIZE + T2_SIZE + T3_SIZE);
        uint256 id = _request(alice, 2, 300_000e6);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        DeosxVault.TrancheView memory t = vault.trancheInfo(2);
        assertEq(t.room, 300_000e6);
        assertEq(t.taken, T3_SIZE - 300_000e6);

        _deposit(bob, 300_000e6);
        assertEq(_lp(2).balanceOf(bob), 300_000e6);
        assertEq(vault.trancheInfo(2).room, 0);
    }

    /// A pending request doesn't free room: only a paid one does.
    function test_T3_PendingRequestKeepsRoomClosed() public {
        _deposit(alice, T1_SIZE + T2_SIZE + T3_SIZE);
        _request(alice, 2, 300_000e6);
        assertEq(vault.trancheInfo(2).room, 0);
    }

    // ----- introducer fees -----

    function test_PayIntroducerFee_FromThatTranchesPot() public {
        _deposit(alice, 1_000_000e6);
        _fundInterest(0, 250_000e6);
        uint256 id = _request(alice, 0, 1_000_000e6);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 150_000e6);

        vm.expectEmit(address(vault));
        emit DeosxVault.IntroducerFeePaid(id, carol, 100_000e6);
        vm.prank(safe);
        vault.payIntroducerFee(id, 100_000e6);
        assertEq(usdt.balanceOf(carol), 100_000e6);
        assertEq(vault.trancheInfo(0).interestPot, 0);
        assertEq(vault.totalInterestPot(), 0);
        DeosxVault.Request memory r = vault.getRequest(id);
        assertEq(uint8(r.feeStatus), uint8(DeosxVault.FeeStatus.Paid));
        assertEq(r.fee, 100_000e6);
        assertEq(vault.feesDue().length, 0);
    }

    /// Interest and fees for T2 and T3 requests come out of that tranche's pot and leave the other pots alone.
    function test_InterestAndFee_FromT2AndT3Pots() public {
        _deposit(alice, T1_SIZE + T2_SIZE + 300_000e6); // 2M in T1, 3M in T2, 300k in T3
        _fundInterest(0, 100_000e6);
        _fundInterest(1, 100_000e6);
        _fundInterest(2, 100_000e6);
        uint256 inT2 = _request(alice, 1, 500_000e6);

        vm.startPrank(safe);
        vault.fulfillWithdraw(inT2, 30_000e6);
        _assertPots(100_000e6, 70_000e6, 100_000e6);
        vault.payIntroducerFee(inT2, 20_000e6);
        _assertPots(100_000e6, 50_000e6, 100_000e6);
        vm.stopPrank();

        uint256 inT3 = _request(alice, 2, 300_000e6);
        vm.startPrank(safe);
        vault.fulfillWithdraw(inT3, 40_000e6);
        _assertPots(100_000e6, 50_000e6, 60_000e6);
        vault.payIntroducerFee(inT3, 10_000e6);
        _assertPots(100_000e6, 50_000e6, 50_000e6);
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), 800_000e6 + 70_000e6);
        assertEq(usdt.balanceOf(carol), 30_000e6);
        assertEq(vault.getRequest(inT2).fee, 20_000e6);
        assertEq(vault.getRequest(inT3).fee, 10_000e6);
    }

    function _assertPots(uint256 t1, uint256 t2, uint256 t3) private view {
        assertEq(vault.trancheInfo(0).interestPot, t1, "T1 pot");
        assertEq(vault.trancheInfo(1).interestPot, t2, "T2 pot");
        assertEq(vault.trancheInfo(2).interestPot, t3, "T3 pot");
        assertEq(vault.totalInterestPot(), t1 + t2 + t3, "total pot");
    }

    function test_PayIntroducerFee_OnceOnly() public {
        _deposit(alice, OPENING);
        _fundInterest(0, 10_000e6);
        uint256 id = _request(alice, 0, OPENING);
        vm.startPrank(safe);
        vault.fulfillWithdraw(id, 0);
        vault.payIntroducerFee(id, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.FeeNotDue.selector, id));
        vault.payIntroducerFee(id, 1_000e6);
        vm.stopPrank();
    }

    /// Zero closes the fee without a transfer.
    function test_PayIntroducerFee_ZeroClosesIt() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        vm.startPrank(safe);
        vault.fulfillWithdraw(id, 0);
        vault.payIntroducerFee(id, 0);
        vm.stopPrank();
        assertEq(uint8(vault.getRequest(id).feeStatus), uint8(DeosxVault.FeeStatus.Paid));
        assertEq(vault.feesDue().length, 0);
    }

    function test_PayIntroducerFee_RevertWhen_NotDue() public {
        _deposit(alice, OPENING);
        _deposit(bob, OPENING);
        uint256 pending = _request(alice, 0, OPENING);
        uint256 noIntroducer = _request(bob, 0, OPENING);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.FeeNotDue.selector, pending));
        vault.payIntroducerFee(pending, 0);
        vault.fulfillWithdraw(noIntroducer, 0);
        assertEq(uint8(vault.getRequest(noIntroducer).feeStatus), uint8(DeosxVault.FeeStatus.None));
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.FeeNotDue.selector, noIntroducer));
        vault.payIntroducerFee(noIntroducer, 0);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.FeeNotDue.selector, 99));
        vault.payIntroducerFee(99, 0);
        vm.stopPrank();
    }

    function test_PayIntroducerFee_RevertWhen_AbovePot() public {
        _deposit(alice, OPENING);
        _fundInterest(0, 5_000e6);
        uint256 id = _request(alice, 0, OPENING);
        vm.startPrank(safe);
        vault.fulfillWithdraw(id, 0);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InsufficientInterest.selector, 5_000e6, 5_000e6 + 1));
        vault.payIntroducerFee(id, 5_000e6 + 1);
        vm.stopPrank();
    }

    /// A failed fee transfer reverts as a whole: the fee stays due and can be paid later.
    function test_PayIntroducerFee_FailedTransfer_StaysDue() public {
        _deposit(alice, OPENING);
        _fundInterest(0, 5_000e6);
        uint256 id = _request(alice, 0, OPENING);
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        // USDT's blacklist blocks the sender only, so this is the case that stops a payment.
        usdt.setBlackListed(address(vault), true);
        vm.prank(safe);
        vm.expectRevert();
        vault.payIntroducerFee(id, 1_000e6);
        assertEq(uint8(vault.getRequest(id).feeStatus), uint8(DeosxVault.FeeStatus.Due));
    }

    // ----- fuzz -----

    /// Any request split by tier adds up to the amount, and paying it moves exactly capital plus interest.
    function testFuzz_RequestAndFulfill(
        uint256 a,
        uint256 b,
        uint256 gap,
        uint256 wait,
        uint256 amount,
        uint256 interest
    ) public {
        a = bound(a, OPENING, 1_000_000e6);
        b = bound(b, TOPUP, 1_000_000e6);
        gap = bound(gap, 0, 200 days);
        wait = bound(wait, 0, 200 days);
        _deposit(alice, a);
        vm.warp(T0 + gap);
        _deposit(alice, b);
        vm.warp(T0 + gap + wait);

        uint256 total = vault.available(alice, 0) + vault.available(alice, 1);
        amount = bound(amount, 1, vault.available(alice, 0));
        interest = bound(interest, 0, 500_000e6);
        _fundInterest(0, 500_000e6);
        uint256 id = _request(alice, 0, amount);
        DeosxVault.Request memory r = vault.getRequest(id);
        assertEq(r.heldUnderHalf + r.heldHalf + r.heldFull, amount);

        vm.prank(safe);
        vault.fulfillWithdraw(id, interest);
        assertEq(usdt.balanceOf(alice), amount + interest);
        assertEq(vault.capitalOf(alice), total - amount);
        assertEq(_lp(0).balanceOf(alice) + _lp(1).balanceOf(alice), total - amount);
        uint256 sum;
        DeosxVault.PositionView[] memory p = vault.positionsOf(alice, 0);
        for (uint256 j; j < p.length; ++j) {
            sum += p[j].amount;
        }
        assertEq(sum, _lp(0).balanceOf(alice));
    }

    // A model of alice's positions in T3, oldest first.
    uint256[] private _mAmount;
    uint64[] private _mAt;

    /// Random sequences of deposits, requests, cancels, payouts and warps by one wallet in T3, one request open at a
    /// time. After every step: a second request reverts while one is open; the open request's split is the model's
    /// oldest-first split at its `requestedAt` and never changes while it is pending; it is paid on exactly that
    /// split; positions match the model; pending plus available is the LP held.
    function testFuzz_RandomOps_OneOpenRequest(uint256 seed) public {
        _deposit(bob, T1_SIZE + T2_SIZE); // fills T1 and T2, so alice lands in T3
        _fundInterest(2, 1_000_000e6);
        _mDeposit(OPENING);
        DeosxVault.Request memory made;
        for (uint256 step; step < 60; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = seed % 5;
            uint256 pick = seed >> 8;
            uint256 open = vault.openRequestOf(alice);
            if (op == 0) {
                // After a full exit the next deposit is an opening one again.
                _mDeposit((vault.capitalOf(alice) == 0 ? OPENING : TOPUP) + pick % 200_000e6);
            } else if (op == 1) {
                uint256 free = vault.available(alice, 2);
                if (open != 0) {
                    vm.prank(alice);
                    vm.expectRevert(abi.encodeWithSelector(DeosxVault.RequestPending.selector, open));
                    vault.requestWithdraw(2, free == 0 ? 1 : free);
                    continue;
                }
                if (free == 0) continue;
                uint256 id = _request(alice, 2, 1 + pick % free);
                made = vault.getRequest(id);
                (uint256 under, uint256 half, uint256 full) = _modelSplit(made.amount, made.requestedAt);
                assertEq(made.heldUnderHalf, under, "split: under half");
                assertEq(made.heldHalf, half, "split: half");
                assertEq(made.heldFull, full, "split: full");
            } else if (op == 2 && open != 0) {
                vm.prank(alice);
                vault.cancelWithdraw(open);
            } else if (op == 3 && open != 0) {
                vm.prank(safe);
                vault.fulfillWithdraw(open, 1);
                DeosxVault.Request memory paid = vault.getRequest(open);
                assertEq(paid.heldUnderHalf, made.heldUnderHalf, "paid on the split made");
                assertEq(paid.heldHalf, made.heldHalf, "paid on the split made");
                assertEq(paid.heldFull, made.heldFull, "paid on the split made");
                _modelConsume(made.amount);
            } else {
                vm.warp(block.timestamp + pick % 50 days);
            }

            open = vault.openRequestOf(alice);
            uint256 pending;
            if (open != 0) {
                DeosxVault.Request memory r = vault.getRequest(open);
                assertEq(uint8(r.status), uint8(DeosxVault.RequestStatus.Pending), "open is pending");
                assertEq(abi.encode(r), abi.encode(made), "pending request never changes");
                pending = r.amount;
            }
            assertEq(vault.pendingRequests().length, open == 0 ? 0 : 1, "at most one pending");
            assertEq(pending, vault.reserved(alice, 2), "pending = reserved");
            assertEq(pending + vault.available(alice, 2), _lp(2).balanceOf(alice), "pending + available = LP");
            _checkPositions();
        }
    }

    function _mDeposit(uint256 amount) private {
        _deposit(alice, amount);
        _mAmount.push(amount);
        _mAt.push(uint64(block.timestamp));
    }

    /// @dev The model's split of the oldest `amount` units by how long each had been held at `asOf`.
    function _modelSplit(uint256 amount, uint64 asOf) private view returns (uint256 under, uint256 half, uint256 full) {
        for (uint256 j; j < _mAmount.length && amount > 0; ++j) {
            uint256 take = _mAmount[j] < amount ? _mAmount[j] : amount;
            amount -= take;
            uint64 held = asOf - _mAt[j];
            if (held < HALF) under += take;
            else if (held < FULL) half += take;
            else full += take;
        }
    }

    function _modelConsume(uint256 amount) private {
        for (uint256 j; j < _mAmount.length && amount > 0; ++j) {
            uint256 take = _mAmount[j] < amount ? _mAmount[j] : amount;
            _mAmount[j] -= take;
            amount -= take;
        }
    }

    function _checkPositions() private view {
        DeosxVault.PositionView[] memory p = vault.positionsOf(alice, 2);
        uint256 n;
        for (uint256 j; j < _mAmount.length; ++j) {
            if (_mAmount[j] == 0) continue;
            assertEq(p[n].amount, _mAmount[j], "position amount");
            assertEq(p[n].depositedAt, _mAt[j], "position date");
            ++n;
        }
        assertEq(p.length, n, "position count");
    }
}
