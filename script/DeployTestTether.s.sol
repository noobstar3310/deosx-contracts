// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {TestTether} from "../src/testnet/TestTether.sol";
import {SEPOLIA_CHAIN_ID} from "./Deploy.s.sol";

/// @notice Deploys the test USDT. Sepolia only.
contract DeployTestTether is Script {
    error SepoliaOnly(uint256 chainId);

    function run() external returns (TestTether token) {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert SepoliaOnly(block.chainid);
        vm.startBroadcast();
        token = new TestTether();
        vm.stopBroadcast();
    }
}
