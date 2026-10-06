// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

/// @notice How much gas a withdrawal costs when the wallet holds many positions in one tranche.
/// `requestWithdraw` (via `_snapshot`) and `fulfillWithdraw` (via `_consumeOldest`) walk the wallet's positions one by
/// one, oldest first, so their cost grows with the number of positions the request covers. Ethereum caps a single
/// transaction at 2^24 gas (EIP-7825), so that number has a ceiling. Each test runs with `isolate`, so every call is
/// its own transaction and storage written by earlier calls is priced as on mainnet; without it, clearing a slot
/// written earlier in the same test is priced as a cheap same-transaction reset and payouts look half as expensive.
contract DeosxVaultGasTest is VaultTestBase {
    uint256 internal constant TX_GAS_CAP = 16_777_216; // 2^24, EIP-7825
    uint256 internal constant T3 = 2;

    /// @dev Fills T1 and T2 with someone else's money so every deposit after it lands in T3.
    function _fillT1T2() internal {
        _deposit(bob, T1_SIZE + T2_SIZE);
    }

    /// @dev Gives `alice` one opening position of `OPENING` then `n - 1` top-ups of `topUp`, all in T3.
    function _buildPositions(uint256 n, uint256 topUp) internal returns (uint256 total) {
        _deposit(alice, OPENING);
        total = OPENING;
        for (uint256 i = 1; i < n; ++i) {
            _deposit(alice, topUp);
            total += topUp;
        }
        assertEq(vault.positionsOf(alice, T3).length, n);
    }

    /// @dev Requests and pays `amount` of alice's T3 capital; returns each call's gas before storage refunds, which
    /// is what has to fit under the per-transaction cap (the 21,000 base cost is added at the comparisons).
    function _measure(uint256 amount) internal returns (uint256 requestGas, uint256 payGas) {
        uint256 id;
        (id, requestGas) = _requestGas(amount);
        payGas = _payGas(id);
    }

    function _requestGas(uint256 amount) internal returns (uint256 id, uint256 used) {
        vm.prank(alice);
        id = vault.requestWithdraw(T3, amount);
        used = _lastCallGasBeforeRefund();
    }

    function _payGas(uint256 id) internal returns (uint256 used) {
        vm.prank(safe);
        vault.fulfillWithdraw(id, 0);
        used = _lastCallGasBeforeRefund();
    }

    /// @dev With `isolate` on, every call from the test is its own transaction, so storage written by earlier calls is
    /// priced as on mainnet. The cap applies before refunds, so the refund is added back.
    function _lastCallGasBeforeRefund() internal view returns (uint256) {
        int64 refunded = vm.lastCallGas().gasRefunded;
        return vm.lastCallGas().gasTotalUsed + (refunded > 0 ? uint256(uint64(refunded)) : 0);
    }

    /// The most positions a wallet can hold today: all of T3 (15,000,000) as one 100,000 opening deposit plus
    /// 10,000 top-ups = 1,491 positions. Requesting and paying all of it in one go must fit in a transaction.
    /// forge-config: default.isolate = true
    function test_Gas_WorstCaseUnderCurrentMinimums_FitsInOneTransaction() public {
        _fillT1T2();
        uint256 n = 1 + (T3_SIZE - OPENING) / TOPUP; // 1,491
        uint256 total = _buildPositions(n, TOPUP);
        assertEq(total, T3_SIZE);

        (uint256 requestGas, uint256 payGas) = _measure(total);
        console.log("positions", n);
        console.log("requestWithdraw gas", requestGas);
        console.log("fulfillWithdraw gas", payGas);
        console.log("tx cap", TX_GAS_CAP);

        assertLt(requestGas + 21_000, TX_GAS_CAP);
        assertLt(payGas + 21_000, TX_GAS_CAP);
    }

    /// Cost per position, from two sizes, so the break-even point can be read off for any minimum.
    /// forge-config: default.isolate = true
    function test_Gas_PerPositionCostAndBreakPoint() public {
        uint256 small = 200;
        uint256 large = 1_200;

        _fillT1T2();
        uint256 totalSmall = _buildPositions(small, TOPUP);
        (uint256 reqSmall, uint256 paySmall) = _measure(totalSmall);

        setUp();
        _fillT1T2();
        uint256 totalLarge = _buildPositions(large, TOPUP);
        (uint256 reqLarge, uint256 payLarge) = _measure(totalLarge);

        uint256 reqPer = (reqLarge - reqSmall) / (large - small);
        uint256 payPer = (payLarge - paySmall) / (large - small);
        uint256 reqBase = reqSmall - reqPer * small;
        uint256 payBase = paySmall - payPer * small;
        uint256 reqMax = (TX_GAS_CAP - 21_000 - reqBase) / reqPer;
        uint256 payMax = (TX_GAS_CAP - 21_000 - payBase) / payPer;

        console.log("requestWithdraw gas per position", reqPer);
        console.log("fulfillWithdraw gas per position", payPer);
        console.log("max positions in one requestWithdraw", reqMax);
        console.log("max positions in one fulfillWithdraw", payMax);

        // Today's rules allow at most 1,491 positions per wallet per tranche; the ceiling must sit above that.
        uint256 todaysMax = 1 + (T3_SIZE - OPENING) / TOPUP;
        assertGt(reqMax, todaysMax);
        assertGt(payMax, todaysMax);
    }

    /// If the Safe lowers the top-up minimum to 1 USDT, a wallet can hold far more positions than one transaction can
    /// walk. A request for all of them then runs out of gas. A request for part of the capital only walks the
    /// positions it covers, so the investor can still leave in several smaller requests.
    /// forge-config: default.isolate = true
    function test_Gas_LoweredTopUp_FullRequestTooBig_PartialRequestsStillWork() public {
        vm.prank(safe);
        vault.setMinimums(OPENING, 1e6);
        _fillT1T2();
        uint256 n = 3_300;
        uint256 total = _buildPositions(n, 1e6);

        // All 3,300 positions in one request: over the per-transaction cap.
        (uint256 id, uint256 fullRequestGas) = _requestGas(total);
        console.log("positions", n);
        console.log("requestWithdraw gas for all of them", fullRequestGas);
        assertGt(fullRequestGas + 21_000, TX_GAS_CAP);
        vm.prank(alice);
        vault.cancelWithdraw(id);

        // The oldest 1,000 positions (the 100,000 opening one plus 999 top-ups of 1 USDT) in one request: fits.
        uint256 part = OPENING + 999e6;
        (uint256 requestGas, uint256 payGas) = _measure(part);
        console.log("requestWithdraw gas for 1,000 of them", requestGas);
        console.log("fulfillWithdraw gas for 1,000 of them", payGas);
        assertLt(requestGas + 21_000, TX_GAS_CAP);
        assertLt(payGas + 21_000, TX_GAS_CAP);
        assertEq(vault.positionsOf(alice, T3).length, n - 1_000);
    }
}
