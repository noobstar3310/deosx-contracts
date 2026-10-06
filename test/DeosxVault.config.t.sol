// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeosxVault} from "../src/DeosxVault.sol";
import {TrancheToken} from "../src/TrancheToken.sol";
import {VaultTestBase} from "./utils/VaultTestBase.sol";

contract DeosxVaultConfigTest is VaultTestBase {
    function test_Constructor_SetsSettings() public view {
        assertEq(vault.owner(), safe);
        assertEq(address(vault.usdt()), address(usdt));
        assertEq(vault.halfTierAfter(), HALF);
        assertEq(vault.fullTierAfter(), FULL);
        assertEq(vault.openingMinimum(), OPENING);
        assertEq(vault.topUpMinimum(), TOPUP);
        assertEq(vault.TRANCHE_COUNT(), 3);
        uint256[3] memory sizes = _sizes();
        for (uint256 i; i < 3; ++i) {
            DeosxVault.TrancheView memory t = vault.trancheInfo(i);
            assertEq(t.size, sizes[i]);
            assertEq(t.room, sizes[i]);
            assertEq(t.taken + t.capital + t.interestPot, 0);
        }
    }

    function test_Constructor_CreatesOneLpTokenPerTranche() public view {
        string[3] memory symbols = ["dxT1", "dxT2", "dxT3"];
        for (uint256 i; i < 3; ++i) {
            TrancheToken lp = TrancheToken(vault.trancheInfo(i).lpToken);
            assertEq(lp.vault(), address(vault));
            assertEq(lp.decimals(), 6);
            assertEq(lp.symbol(), symbols[i]);
            assertEq(lp.name(), string.concat("DEOS-X Yield Tranche ", vm.toString(i + 1)));
        }
    }

    function test_Constructor_RevertWhen_UsdtZero() public {
        vm.expectRevert(DeosxVault.ZeroAddress.selector);
        new DeosxVault(IERC20Metadata(address(0)), safe, _sizes(), HALF, FULL, OPENING, TOPUP);
    }

    function test_Constructor_RevertWhen_SafeZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DeosxVault(IERC20Metadata(address(usdt)), address(0), _sizes(), HALF, FULL, OPENING, TOPUP);
    }

    function test_Constructor_RevertWhen_TiersInvalid() public {
        IERC20Metadata token = IERC20Metadata(address(usdt));
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        new DeosxVault(token, safe, _sizes(), 0, FULL, OPENING, TOPUP);
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        new DeosxVault(token, safe, _sizes(), FULL, FULL, OPENING, TOPUP);
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        new DeosxVault(token, safe, _sizes(), FULL, HALF, OPENING, TOPUP);
    }

    function test_Constructor_RevertWhen_SizeZero() public {
        for (uint256 i; i < 3; ++i) {
            uint256[3] memory sizes = _sizes();
            sizes[i] = 0;
            vm.expectRevert(DeosxVault.InvalidConfig.selector);
            new DeosxVault(IERC20Metadata(address(usdt)), safe, sizes, HALF, FULL, OPENING, TOPUP);
        }
    }

    /// The constructor holds the minimums to the same bounds as `setMinimums`: top-up never 0, never above opening.
    function test_Constructor_RevertWhen_ZeroTopUpOrAboveOpening() public {
        IERC20Metadata token = IERC20Metadata(address(usdt));
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        new DeosxVault(token, safe, _sizes(), HALF, FULL, OPENING, 0);
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        new DeosxVault(token, safe, _sizes(), HALF, FULL, 0, 0);
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        new DeosxVault(token, safe, _sizes(), HALF, FULL, TOPUP - 1, TOPUP);
        DeosxVault v = new DeosxVault(token, safe, _sizes(), HALF, FULL, TOPUP, TOPUP);
        assertEq(v.openingMinimum(), TOPUP);
        assertEq(v.topUpMinimum(), TOPUP);
    }

    function test_TrancheViews_RevertWhen_UnknownTranche() public {
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.UnknownTranche.selector, 3));
        vault.trancheInfo(3);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.UnknownTranche.selector, 3));
        vault.positionsOf(alice, 3);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.UnknownTranche.selector, 3));
        vault.available(alice, 3);
    }

    // ----- operators -----

    function test_SetOperator_OnlyOwner() public {
        address dave = makeAddr("dave");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vault.setOperator(dave, true);

        vm.expectEmit(address(vault));
        emit DeosxVault.OperatorSet(dave, true);
        vm.prank(safe);
        vault.setOperator(dave, true);
        assertTrue(vault.isOperator(dave));

        vm.prank(safe);
        vault.setOperator(dave, false);
        assertFalse(vault.isOperator(dave));
    }

    function test_SetOperator_RevertWhen_Zero() public {
        vm.prank(safe);
        vm.expectRevert(DeosxVault.ZeroAddress.selector);
        vault.setOperator(address(0), true);
    }

    function test_RemovedOperator_LosesAccess() public {
        vm.prank(safe);
        vault.setOperator(operator, false);
        vm.prank(operator);
        vm.expectRevert(DeosxVault.NotOperator.selector);
        vault.setWhitelisted(otc, true);
    }

    // ----- whitelist and introducers -----

    function test_SetWhitelisted_ByOperatorOrOwner() public {
        vm.expectEmit(address(vault));
        emit DeosxVault.WhitelistSet(otc, true);
        vm.prank(operator);
        vault.setWhitelisted(otc, true);
        assertTrue(vault.isWhitelisted(otc));

        vm.prank(safe);
        vault.setWhitelisted(otc, false);
        assertFalse(vault.isWhitelisted(otc));
    }

    function test_SetWhitelisted_RevertWhen_NotOperator() public {
        vm.prank(alice);
        vm.expectRevert(DeosxVault.NotOperator.selector);
        vault.setWhitelisted(otc, true);
    }

    function test_SetWhitelisted_RevertWhen_Zero() public {
        vm.prank(operator);
        vm.expectRevert(DeosxVault.ZeroAddress.selector);
        vault.setWhitelisted(address(0), true);
    }

    function test_SetIntroducer_ByOperator() public {
        vm.expectEmit(address(vault));
        emit DeosxVault.IntroducerSet(bob, carol);
        vm.prank(operator);
        vault.setIntroducer(bob, carol);
        assertEq(vault.introducerOf(bob), carol);

        vm.prank(operator);
        vault.setIntroducer(bob, address(0));
        assertEq(vault.introducerOf(bob), address(0));
    }

    function test_SetIntroducer_RevertWhen_NotOperatorOrZeroWallet() public {
        vm.prank(alice);
        vm.expectRevert(DeosxVault.NotOperator.selector);
        vault.setIntroducer(bob, carol);
        vm.prank(operator);
        vm.expectRevert(DeosxVault.ZeroAddress.selector);
        vault.setIntroducer(address(0), carol);
    }

    /// The vault as introducer would move pot money onto the capital side when the fee is paid.
    function test_SetIntroducer_RevertWhen_Vault() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.InvalidRecipient.selector, address(vault)));
        vault.setIntroducer(bob, address(vault));
        assertEq(vault.introducerOf(bob), address(0));
    }

    // ----- owner settings -----

    function test_SetMinimums_OnlyOwner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vault.setMinimums(1, 1);

        vm.expectEmit(address(vault));
        emit DeosxVault.MinimumsSet(50_000e6, 5_000e6);
        vm.prank(safe);
        vault.setMinimums(50_000e6, 5_000e6);
        assertEq(vault.openingMinimum(), 50_000e6);
        assertEq(vault.topUpMinimum(), 5_000e6);
    }

    /// The top-up minimum is never 0 and never above the opening minimum; equal is fine.
    function test_SetMinimums_RevertWhen_ZeroTopUpOrAboveOpening() public {
        vm.startPrank(safe);
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        vault.setMinimums(OPENING, 0);
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        vault.setMinimums(0, 0);
        vm.expectRevert(DeosxVault.InvalidConfig.selector);
        vault.setMinimums(TOPUP - 1, TOPUP);
        vault.setMinimums(TOPUP, TOPUP);
        vm.stopPrank();
        assertEq(vault.openingMinimum(), TOPUP);
        assertEq(vault.topUpMinimum(), TOPUP);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vault.pause();
        vm.prank(safe);
        vault.pause();
        assertTrue(vault.paused());
        vm.prank(safe);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_RenounceOwnership_Disabled() public {
        vm.prank(safe);
        vm.expectRevert(DeosxVault.RenounceDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), safe);
    }

    function test_TransferOwnership_TwoStep() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(safe);
        vault.transferOwnership(newSafe);
        assertEq(vault.owner(), safe);
        vm.prank(newSafe);
        vault.acceptOwnership();
        assertEq(vault.owner(), newSafe);
    }

    // ----- staff and investors are kept apart -----

    function test_SetWhitelisted_RevertWhen_Operator() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.RoleConflict.selector, operator));
        vault.setWhitelisted(operator, true);
        assertFalse(vault.isWhitelisted(operator));
    }

    function test_SetWhitelisted_RevertWhen_Owner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.RoleConflict.selector, safe));
        vault.setWhitelisted(safe, true);
        assertFalse(vault.isWhitelisted(safe));
    }

    /// A Safe that is about to take over can't be whitelisted between the two ownership steps.
    function test_SetWhitelisted_RevertWhen_PendingOwner() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(safe);
        vault.transferOwnership(newSafe);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.RoleConflict.selector, newSafe));
        vault.setWhitelisted(newSafe, true);
    }

    function test_SetOperator_RevertWhen_Whitelisted() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.RoleConflict.selector, alice));
        vault.setOperator(alice, true);
        assertFalse(vault.isOperator(alice));
    }

    function test_TransferOwnership_RevertWhen_Whitelisted() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeosxVault.RoleConflict.selector, alice));
        vault.transferOwnership(alice);
        assertEq(vault.pendingOwner(), address(0));
    }

    /// Removing is never blocked, so a conflict can always be cleared.
    function test_Removals_AlwaysAllowed() public {
        vm.startPrank(safe);
        vault.setOperator(operator, false);
        vault.setWhitelisted(alice, false);
        vault.setWhitelisted(operator, false);
        vault.setOperator(alice, false);
        vm.stopPrank();
        assertFalse(vault.isOperator(operator));
        assertFalse(vault.isWhitelisted(alice));
    }

    /// Roles can move in order: an investor removed from the whitelist can become an operator, and back.
    function test_RoleSwitch_AfterRemoval() public {
        vm.startPrank(safe);
        vault.setWhitelisted(alice, false);
        vault.setOperator(alice, true);
        assertTrue(vault.isOperator(alice));
        vault.setOperator(alice, false);
        vault.setWhitelisted(alice, true);
        vm.stopPrank();
        assertTrue(vault.isWhitelisted(alice));
    }

    function test_OwnerFunctions_RevertWhen_NotOwner() public {
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator);
        vm.startPrank(operator);
        vm.expectRevert(denied);
        vault.fundInterest(0, 1);
        vm.expectRevert(denied);
        vault.withdrawInterest(0, 1);
        vm.expectRevert(denied);
        vault.transferOut(otc, 1);
        vm.expectRevert(denied);
        vault.returnCapital(1);
        vm.expectRevert(denied);
        vault.fulfillWithdraw(1, 0);
        vm.expectRevert(denied);
        vault.payIntroducerFee(1, 0);
        vm.stopPrank();
    }
}
