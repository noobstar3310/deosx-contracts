// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeosxVault} from "../src/DeosxVault.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

contract DeosxVaultInvariantTest is VaultTestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, usdt, safe);
        targetContract(address(handler));
        // Only the actions: the handler's public getters would waste about half the calls.
        bytes4[] memory actions = new bytes4[](16);
        actions[0] = VaultHandler.deposit.selector;
        actions[1] = VaultHandler.request.selector;
        actions[2] = VaultHandler.cancel.selector;
        actions[3] = VaultHandler.fulfill.selector;
        actions[4] = VaultHandler.payFee.selector;
        actions[5] = VaultHandler.fundInterest.selector;
        actions[6] = VaultHandler.withdrawInterest.selector;
        actions[7] = VaultHandler.transferOut.selector;
        actions[8] = VaultHandler.returnCapital.selector;
        actions[9] = VaultHandler.warp.selector;
        actions[10] = VaultHandler.setWhitelisted.selector;
        actions[11] = VaultHandler.setIntroducer.selector;
        actions[12] = VaultHandler.setMinimums.selector;
        actions[13] = VaultHandler.togglePause.selector;
        actions[14] = VaultHandler.handOver.selector;
        actions[15] = VaultHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    /// Every tranche's capital is its LP supply and within its size; T1 and T2 never give room back, T3 has exactly
    /// its capital's worth taken.
    function invariant_CapitalEqualsLpSupply() public view {
        for (uint256 i; i < 3; ++i) {
            DeosxVault.TrancheView memory t = vault.trancheInfo(i);
            assertEq(t.capital, IERC20(t.lpToken).totalSupply(), "capital = LP supply");
            assertLe(t.capital, t.size, "capital <= size");
            assertLe(t.taken, t.size, "taken <= size");
            assertEq(t.room, t.size - t.taken, "room = size - taken");
            if (i < 2) assertLe(t.capital, t.taken, "T1, T2: capital <= taken");
            else assertEq(t.capital, t.taken, "T3: capital = taken");
        }
    }

    /// The USDT in the vault is the interest pots plus the capital not deployed, to the unit. USDT sent by plain
    /// transfer lands on the capital side untracked, so capital held + deployed exceeds capital owed by exactly that
    /// (KNOWN_ISSUES §1).
    function invariant_UsdtAccountsExactly() public view {
        (uint256 inVault, uint256 owed, uint256 pots, uint256 cash, uint256 deployed) = vault.vaultState();
        assertEq(inVault, cash + pots, "balance = cash + pots");
        assertEq(cash + deployed, owed + handler.ghostDonated(), "capital held + deployed = capital owed + donated");
        assertEq(
            inVault,
            handler.ghostDeposited() + handler.ghostInterestFunded() + handler.ghostReturned() + handler.ghostDonated()
                - handler.ghostCapitalPaid() - handler.ghostInterestPaid() - handler.ghostFeesPaid()
                - handler.ghostInterestWithdrawn() - handler.ghostOut(),
            "balance = in - out"
        );
    }

    /// Staff and investors stay apart: no investor (whitelisted or holding capital) is an operator, the owner or
    /// the pending owner, and the owner is never whitelisted.
    function invariant_StaffAndInvestorsApart() public view {
        uint256 n = handler.investorCount();
        for (uint256 k; k < n; ++k) {
            address who = handler.investors(k);
            if (!vault.isWhitelisted(who) && vault.capitalOf(who) == 0) continue;
            assertFalse(vault.isOperator(who), "investor is not an operator");
            assertTrue(vault.owner() != who && vault.pendingOwner() != who, "investor is not the owner");
        }
        assertFalse(vault.isWhitelisted(vault.owner()), "owner is not whitelisted");
    }

    /// The minimums stay ordered: 0 < top-up <= opening.
    function invariant_MinimumsOrdered() public view {
        assertGt(vault.topUpMinimum(), 0, "top-up > 0");
        assertLe(vault.topUpMinimum(), vault.openingMinimum(), "top-up <= opening");
    }

    /// The pots add up to `totalInterestPot`, which is everything funded less what was paid out of or taken back
    /// from them.
    function invariant_PotsSumToTotal() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += vault.trancheInfo(i).interestPot;
        }
        assertEq(sum, vault.totalInterestPot());
        assertEq(
            sum,
            handler.ghostInterestFunded() - handler.ghostInterestPaid() - handler.ghostFeesPaid()
                - handler.ghostInterestWithdrawn()
        );
    }

    /// Each investor's capital, positions, LP and reserve agree; nothing is reserved that isn't held.
    function invariant_PerInvestorBooks() public view {
        uint256 n = handler.investorCount();
        for (uint256 k; k < n; ++k) {
            address who = handler.investors(k);
            uint256 total;
            for (uint256 i; i < 3; ++i) {
                uint256 lp = IERC20(vault.trancheInfo(i).lpToken).balanceOf(who);
                DeosxVault.PositionView[] memory p = vault.positionsOf(who, i);
                uint256 sum;
                for (uint256 j; j < p.length; ++j) {
                    sum += p[j].amount;
                }
                assertEq(sum, lp, "positions = LP");
                assertEq(vault.available(who, i) + vault.reserved(who, i), lp, "available + reserved = LP");
                total += lp;
            }
            assertEq(vault.capitalOf(who), total, "capitalOf = LP across tranches");
        }
    }

    /// Each tranche's pot is exactly what was funded into it less the interest and fees paid from it and what was
    /// taken back from it: no pot ever pays for another tranche.
    function invariant_EachPotMatchesItsOwnFlows() public view {
        for (uint256 i; i < 3; ++i) {
            assertEq(
                vault.trancheInfo(i).interestPot,
                handler.ghostFundedIn(i) - handler.ghostInterestPaidIn(i) - handler.ghostFeesPaidIn(i)
                    - handler.ghostWithdrawnIn(i),
                "pot = funded - interest - fees - withdrawn, per tranche"
            );
        }
    }

    /// Every pending request is reserved by its owner; the pending reserves add up to each reserve.
    function invariant_PendingMatchesReserved() public view {
        uint256[] memory ids = vault.pendingRequests();
        uint256 n = handler.investorCount();
        for (uint256 k; k < n; ++k) {
            address who = handler.investors(k);
            for (uint256 i; i < 3; ++i) {
                uint256 sum;
                for (uint256 j; j < ids.length; ++j) {
                    DeosxVault.Request memory r = vault.getRequest(ids[j]);
                    if (r.owner == who && r.tranche == i) sum += r.amount;
                }
                assertEq(sum, vault.reserved(who, i), "pending = reserved");
            }
        }
    }

    /// Every wallet has at most one pending request: `openRequestOf` names it (pending, owned by the wallet) and the
    /// wallet's reserve, summed over the tranches, is that request's amount, all of it in the request's tranche. A
    /// wallet with `openRequestOf` 0 has no pending request and nothing reserved.
    function invariant_OneOpenRequestPerWallet() public view {
        uint256[] memory ids = vault.pendingRequests();
        uint256 n = handler.investorCount();
        for (uint256 k; k < n; ++k) {
            address who = handler.investors(k);
            uint256 open = vault.openRequestOf(who);
            uint256 mine;
            for (uint256 j; j < ids.length; ++j) {
                if (vault.getRequest(ids[j]).owner == who) ++mine;
            }
            uint256 reservedSum = vault.reserved(who, 0) + vault.reserved(who, 1) + vault.reserved(who, 2);
            if (open == 0) {
                assertEq(mine, 0, "no open request: none pending");
                assertEq(reservedSum, 0, "no open request: nothing reserved");
            } else {
                DeosxVault.Request memory r = vault.getRequest(open);
                assertEq(uint8(r.status), uint8(DeosxVault.RequestStatus.Pending), "open request is pending");
                assertEq(r.owner, who, "open request is the wallet's");
                assertEq(mine, 1, "exactly one pending");
                assertEq(reservedSum, r.amount, "reserved = open amount");
                assertEq(vault.reserved(who, r.tranche), r.amount, "reserved in its tranche");
            }
        }
    }

    /// Every pending request's split adds up to its amount and is the split of its wallet's oldest `amount` units in
    /// that tranche at its `requestedAt`.
    function invariant_PendingSplitsAddUp() public view {
        uint256[] memory ids = vault.pendingRequests();
        for (uint256 j; j < ids.length; ++j) {
            DeosxVault.Request memory r = vault.getRequest(ids[j]);
            assertEq(r.heldUnderHalf + r.heldHalf + r.heldFull, r.amount, "split = amount");
            _checkSlice(r);
        }
    }

    /// A pending request's split never changes from the one it was made with.
    function invariant_PendingSplitsNeverChange() public view {
        uint256[] memory ids = vault.pendingRequests();
        for (uint256 j; j < ids.length; ++j) {
            DeosxVault.Request memory r = vault.getRequest(ids[j]);
            uint256[3] memory made = handler.ghostSplit(ids[j]);
            assertEq(r.heldUnderHalf, made[0], "under half unchanged");
            assertEq(r.heldHalf, made[1], "half unchanged");
            assertEq(r.heldFull, made[2], "full unchanged");
        }
    }

    /// The waterfall: no capital in a later tranche was taken while an earlier one had room (T3 can reopen, but T1
    /// and T2 never do, so once a later tranche has taken capital the earlier ones stay full).
    function invariant_WaterfallOrder() public view {
        if (vault.trancheInfo(1).taken > 0) assertEq(vault.trancheInfo(0).room, 0);
        if (vault.trancheInfo(2).taken > 0) assertEq(vault.trancheInfo(1).room, 0);
    }

    /// @dev Walks `r`'s wallet's open positions in its tranche oldest first, takes `r.amount` units and checks `r`
    /// reports their tiers at its `requestedAt`.
    function _checkSlice(DeosxVault.Request memory r) private view {
        DeosxVault.PositionView[] memory p = vault.positionsOf(r.owner, r.tranche);
        uint64 half = vault.halfTierAfter();
        uint64 full = vault.fullTierAfter();
        uint256 left = r.amount;
        uint256[3] memory byTier;
        for (uint256 j; left > 0; ++j) {
            uint256 take = p[j].amount < left ? p[j].amount : left;
            uint64 held = r.requestedAt - p[j].depositedAt;
            byTier[held < half ? 0 : held < full ? 1 : 2] += take;
            left -= take;
        }
        assertEq(r.heldUnderHalf, byTier[0], "slice: under half");
        assertEq(r.heldHalf, byTier[1], "slice: half");
        assertEq(r.heldFull, byTier[2], "slice: full");
    }
}
