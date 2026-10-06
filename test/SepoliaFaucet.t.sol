// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SepoliaFaucet} from "../src/testnet/SepoliaFaucet.sol";

/// A wallet that refuses ETH.
contract Refuser {
    receive() external payable {
        revert();
    }
}

contract SepoliaFaucetTest is Test {
    SepoliaFaucet internal faucet;
    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address payable internal alice = payable(makeAddr("alice"));
    address payable internal bob = payable(makeAddr("bob"));

    uint256 internal constant DRIP = 0.005 ether;
    uint256 internal constant COOLDOWN = 72 hours;

    function setUp() public {
        vm.warp(1_790_000_000);
        faucet = new SepoliaFaucet(owner, relayer, DRIP, COOLDOWN);
        vm.deal(address(faucet), 1 ether);
    }

    function test_Drip_SendsAndRecords() public {
        vm.expectEmit(address(faucet));
        emit SepoliaFaucet.Dripped(alice, DRIP);
        vm.prank(relayer);
        faucet.drip(alice);
        assertEq(alice.balance, DRIP);
        assertEq(faucet.lastDripAt(alice), block.timestamp);
        assertEq(faucet.nextDripAt(alice), block.timestamp + COOLDOWN);
        assertEq(faucet.nextDripAt(bob), 0);
    }

    function test_Drip_RevertWhen_CoolingDown_ThenAllowedAfter() public {
        vm.prank(relayer);
        faucet.drip(alice);
        uint256 at = block.timestamp + COOLDOWN;

        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(SepoliaFaucet.CoolingDown.selector, at));
        vm.prank(relayer);
        faucet.drip(alice);

        // Another wallet is not held back by alice's cooldown.
        vm.prank(relayer);
        faucet.drip(bob);

        vm.warp(at);
        vm.prank(relayer);
        faucet.drip(alice);
        assertEq(alice.balance, 2 * DRIP);
    }

    function test_Drip_RevertWhen_NotRelayer() public {
        vm.expectRevert(SepoliaFaucet.NotRelayer.selector);
        vm.prank(alice);
        faucet.drip(alice);
        vm.expectRevert(SepoliaFaucet.NotRelayer.selector);
        vm.prank(owner);
        faucet.drip(alice);
    }

    function test_Drip_RevertWhen_Empty() public {
        vm.deal(address(faucet), DRIP - 1);
        vm.expectRevert(abi.encodeWithSelector(SepoliaFaucet.FaucetEmpty.selector, DRIP - 1, DRIP));
        vm.prank(relayer);
        faucet.drip(alice);
    }

    function test_Drip_RevertWhen_ZeroOrRefused() public {
        vm.expectRevert(SepoliaFaucet.ZeroAddress.selector);
        vm.prank(relayer);
        faucet.drip(payable(address(0)));

        address payable refuser = payable(address(new Refuser()));
        vm.expectRevert(SepoliaFaucet.TransferFailed.selector);
        vm.prank(relayer);
        faucet.drip(refuser);
        // The failed drip did not start a cooldown.
        assertEq(faucet.lastDripAt(refuser), 0);
    }

    function test_SetRelayer_OnlyOwner() public {
        address next = makeAddr("next");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vm.prank(relayer);
        faucet.setRelayer(next);

        vm.prank(owner);
        faucet.setRelayer(next);
        assertEq(faucet.relayer(), next);

        vm.expectRevert(SepoliaFaucet.NotRelayer.selector);
        vm.prank(relayer);
        faucet.drip(alice);
        vm.prank(next);
        faucet.drip(alice);
    }

    function test_Withdraw_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        faucet.withdraw(alice, 1);

        vm.prank(owner);
        faucet.withdraw(bob, 0.4 ether);
        assertEq(bob.balance, 0.4 ether);
        assertEq(address(faucet).balance, 0.6 ether);
    }

    function test_Receive_AcceptsFunding() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(faucet).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(faucet).balance, 1.5 ether);
    }
}
