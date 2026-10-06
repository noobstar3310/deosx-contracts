// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeosxVault} from "../src/DeosxVault.sol";
import {TrancheToken} from "../src/TrancheToken.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

/// @notice One test per fix made after the pre-audit scan (solidity-auditor, 5 passes, 5 Oct 2026).
contract DeosxVaultAuditFixesTest is VaultTestBase {
    // ----- staff and investors: the role checks count capital, not only the whitelist flag -----

    /// A wallet taken off the whitelist still holds capital, so it is still an investor and can't become an operator.
    function test_SetOperator_RevertWhen_DewhitelistedWalletHoldsCapital() public {
        _deposit(alice, OPENING);
        vm.startPrank(safe);
        vault.setWhitelisted(alice, false);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.RoleConflict.selector, alice));
        vault.setOperator(alice, true);
        vm.stopPrank();
    }

    /// Once its capital is paid out in full, the same wallet can be appointed.
    function test_SetOperator_AllowedAfterFullPayout() public {
        _deposit(alice, OPENING);
        uint256 id = _request(alice, 0, OPENING);
        vm.startPrank(safe);
        vault.fulfillWithdraw(id, 0);
        vault.setWhitelisted(alice, false);
        vault.setOperator(alice, true);
        vm.stopPrank();
        assertTrue(vault.isOperator(alice));
    }

    function test_TransferOwnership_RevertWhen_DewhitelistedWalletHoldsCapital() public {
        _deposit(alice, OPENING);
        vm.startPrank(safe);
        vault.setWhitelisted(alice, false);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.RoleConflict.selector, alice));
        vault.transferOwnership(alice);
        vm.stopPrank();
        assertEq(vault.pendingOwner(), address(0));
    }

    // ----- deposit placement guard -----

    /// The victim previews a T1 placement; a deposit mined first takes the T1 room, so the victim's deposit reverts
    /// instead of landing in T2.
    function test_Deposit_RevertWhen_FrontRunChangesPlacement() public {
        _deposit(bob, T1_SIZE - OPENING); // T1 has OPENING of room left
        uint256[3] memory preview = vault.previewDeposit(OPENING);
        assertEq(preview[0], OPENING);

        _deposit(carolWhitelisted(), OPENING); // mined first: T1 is now full

        usdt.mint(alice, OPENING);
        _approve(alice, OPENING);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.PlacementChanged.selector, 0, 0, OPENING));
        vault.deposit(OPENING, preview);
    }

    /// The preview the depositor passes back is the split it gets when nothing moved in between.
    function test_Deposit_WithPreview_PlacesAsPreviewed() public {
        _deposit(bob, T1_SIZE - 50_000e6);
        uint256[3] memory preview = vault.previewDeposit(OPENING);
        assertEq(preview[0], 50_000e6);
        assertEq(preview[1], 50_000e6);

        usdt.mint(alice, OPENING);
        _approve(alice, OPENING);
        vm.prank(alice);
        vault.deposit(OPENING, preview);
        assertEq(_lp(0).balanceOf(alice), 50_000e6);
        assertEq(_lp(1).balanceOf(alice), 50_000e6);
    }

    // ----- last room below the minimum -----

    /// A new investor can fill the last room even when it is below the opening minimum, but only exactly.
    function test_Deposit_ExactRemainingRoom_ExemptFromMinimum() public {
        uint256 left = 5_000e6; // below both minimums
        _deposit(bob, T1_SIZE + T2_SIZE + T3_SIZE - left);

        usdt.mint(alice, left);
        _approve(alice, left - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.BelowMinimum.selector, left - 1, OPENING));
        vault.deposit(left - 1, ANY_SPLIT);

        _approve(alice, left);
        vm.prank(alice);
        vault.deposit(left, ANY_SPLIT);
        assertEq(vault.capitalOf(alice), left);
        assertEq(vault.trancheInfo(2).room, 0);
    }

    // ----- introducer can't be a token contract -----

    function test_SetIntroducer_RevertWhen_UsdtOrLpToken() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InvalidRecipient.selector, address(usdt)));
        vault.setIntroducer(bob, address(usdt));
        for (uint256 i; i < 3; ++i) {
            address lp = address(_lp(i));
            vm.expectRevert(abi.encodeWithSelector(DeosxVault.InvalidRecipient.selector, lp));
            vault.setIntroducer(bob, lp);
        }
        vm.stopPrank();
    }

    // ----- LP approvals -----

    function test_LpApprove_Reverts() public {
        _deposit(alice, OPENING);
        TrancheToken lp = TrancheToken(address(_lp(0)));
        vm.prank(alice);
        vm.expectRevert(TrancheToken.SharesNonTransferable.selector);
        lp.approve(bob, OPENING);
        assertEq(lp.allowance(alice, bob), 0);
    }

    // ----- tranche sizes bounded so the room sum can't overflow -----

    function test_Constructor_RevertWhen_SizeAboveUint128() public {
        uint256[3] memory sizes = _sizes();
        sizes[2] = uint256(type(uint128).max) + 1;
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        new DeosxVault(IERC20Metadata(address(usdt)), safe, sizes, HALF, FULL, OPENING, TOPUP);
    }

    /// @dev Whitelists carol (the base setup only makes her an introducer) and returns her.
    function carolWhitelisted() internal returns (address) {
        vm.prank(operator);
        vault.setWhitelisted(carol, true);
        return carol;
    }
}
