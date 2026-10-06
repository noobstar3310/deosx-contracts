// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {SepoliaFaucet} from "../src/testnet/SepoliaFaucet.sol";
import {SEPOLIA_CHAIN_ID} from "./Deploy.s.sol";

/// @notice Deploys the portals' ETH faucet: 0.005 ETH per wallet every 72 hours, dripped by RELAYER_ADDRESS (the
/// portals' server key) and owned by the deployer. Sepolia only. Fund it afterwards by sending it Sepolia ETH.
contract DeploySepoliaFaucet is Script {
    uint256 internal constant DRIP = 0.005 ether;
    uint256 internal constant COOLDOWN = 72 hours;

    error SepoliaOnly(uint256 chainId);

    function run() external returns (SepoliaFaucet faucet) {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert SepoliaOnly(block.chainid);
        address relayer = vm.envAddress("RELAYER_ADDRESS");
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        faucet = new SepoliaFaucet(deployer, relayer, DRIP, COOLDOWN);
        vm.stopBroadcast();
    }
}
