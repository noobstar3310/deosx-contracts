// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployTestTether} from "../script/DeployTestTether.s.sol";
import {DeosxVault} from "../src/DeosxVault.sol";
import {TestTether} from "../src/testnet/TestTether.sol";
import {MockTether} from "./mocks/MockTether.sol";

contract EighteenDecimals {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract DeployTest is Test {
    // Written out here, not imported from the script, so a wrong constant there fails these tests.
    uint256 internal constant MAINNET = 1;
    uint256 internal constant SEPOLIA = 11155111;
    address internal constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    Deploy internal script;
    address internal safe = makeAddr("safe");

    function setUp() public {
        script = new Deploy();
        vm.etch(safe, hex"00"); // stands in for a deployed Safe
    }

    function _assertFundTerms(DeosxVault vault) internal view {
        assertEq(vault.trancheInfo(0).size, 2_000_000e6);
        assertEq(vault.trancheInfo(1).size, 3_000_000e6);
        assertEq(vault.trancheInfo(2).size, 15_000_000e6);
        assertEq(vault.openingMinimum(), 100_000e6);
        assertEq(vault.topUpMinimum(), 10_000e6);
    }

    function test_Deploy_MainnetSettings() public {
        vm.chainId(MAINNET);
        vm.etch(MAINNET_USDT, address(new MockTether()).code);
        DeosxVault vault = script.deploy(safe, script.defaults(MAINNET));

        assertEq(vault.owner(), safe);
        assertEq(address(vault.usdt()), MAINNET_USDT);
        assertEq(vault.halfTierAfter(), 60 days);
        assertEq(vault.fullTierAfter(), 90 days);
        _assertFundTerms(vault);
    }

    function test_Deploy_SepoliaSettings() public {
        vm.chainId(SEPOLIA);
        Deploy.Settings memory s = script.defaults(SEPOLIA);
        assertEq(s.usdt, address(0));
        s.usdt = address(new TestTether());
        DeosxVault vault = script.deploy(safe, s);

        assertEq(vault.owner(), safe);
        assertEq(address(vault.usdt()), s.usdt);
        assertEq(vault.halfTierAfter(), 60 minutes);
        assertEq(vault.fullTierAfter(), 90 minutes);
        _assertFundTerms(vault);
    }

    function test_Defaults_RevertWhen_UnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 137));
        script.defaults(137);
    }

    /// Valid settings are not enough: the chain itself must be mainnet or Sepolia.
    function test_Deploy_RevertWhen_UnsupportedChain() public {
        Deploy.Settings memory s = script.defaults(SEPOLIA);
        s.usdt = address(new TestTether());
        vm.chainId(31337);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 31337));
        script.deploy(safe, s);
    }

    /// On mainnet every one of the five settings is fixed, however `deploy` is reached.
    function test_Deploy_RevertWhen_AnyMainnetSettingDiffers() public {
        vm.chainId(MAINNET);
        vm.etch(MAINNET_USDT, address(new MockTether()).code);
        address otherUsdt = address(new MockTether());
        for (uint256 field; field < 5; ++field) {
            Deploy.Settings memory s = script.defaults(MAINNET);
            if (field == 0) s.usdt = otherUsdt;
            else if (field == 1) s.halfTierAfter = 60 minutes;
            else if (field == 2) s.fullTierAfter = 90 minutes;
            else if (field == 3) s.openingMinimum = 1;
            else s.topUpMinimum = 1;
            vm.expectRevert(Deploy.MainnetSettingsAreFixed.selector);
            script.deploy(safe, s);
        }
    }

    function test_Deploy_RevertWhen_SafeHasNoCode() public {
        vm.chainId(MAINNET);
        vm.etch(MAINNET_USDT, address(new MockTether()).code);
        address typo = makeAddr("typo");
        Deploy.Settings memory s = script.defaults(MAINNET);
        vm.expectRevert(abi.encodeWithSelector(Deploy.SafeHasNoCode.selector, typo));
        script.deploy(typo, s);
    }

    /// On Sepolia the script won't guess a token: without USDT_ADDRESS it stops.
    function test_Deploy_RevertWhen_SepoliaUsdtNotSet() public {
        vm.chainId(SEPOLIA);
        Deploy.Settings memory s = script.defaults(SEPOLIA);
        vm.expectRevert(Deploy.UsdtNotSet.selector);
        script.deploy(safe, s);
    }

    function test_Deploy_RevertWhen_UsdtNotSixDecimals() public {
        vm.chainId(MAINNET);
        vm.etch(MAINNET_USDT, address(new EighteenDecimals()).code);
        Deploy.Settings memory s = script.defaults(MAINNET);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UsdtNotSixDecimals.selector, 18));
        script.deploy(safe, s);
    }

    // The three tests below set process-wide environment variables while other tests run in parallel. They are
    // written to pass in any order: each name always gets the same value, and each test asserts only what it set.

    /// Off mainnet every one of the five overrides is applied.
    function test_WithEnvOverrides_AppliesAllFive() public {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("USDT_ADDRESS", vm.toString(MAINNET_USDT));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("HALF_TIER_AFTER", "600");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("FULL_TIER_AFTER", "900");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("OPENING_MINIMUM", "1000000000");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("TOPUP_MINIMUM", "1000000");

        Deploy.Settings memory s = script.withEnvOverrides(script.defaults(SEPOLIA));
        assertEq(s.usdt, MAINNET_USDT);
        assertEq(s.halfTierAfter, 600);
        assertEq(s.fullTierAfter, 900);
        assertEq(s.openingMinimum, 1_000e6);
        assertEq(s.topUpMinimum, 1e6);
    }

    function test_Run_ReadsSafeAndOverridesFromEnv() public {
        vm.chainId(SEPOLIA);
        vm.etch(MAINNET_USDT, address(new MockTether()).code);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("USDT_ADDRESS", vm.toString(MAINNET_USDT));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("SAFE_ADDRESS", vm.toString(safe));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("OPENING_MINIMUM", "1000000000");
        // A 1,000 opening minimum needs a top-up minimum at or below it, or the constructor rejects the pair.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("TOPUP_MINIMUM", "1000000");
        DeosxVault vault = script.run();
        assertEq(vault.owner(), safe);
        assertEq(address(vault.usdt()), MAINNET_USDT);
        assertEq(vault.openingMinimum(), 1_000e6);
        assertEq(vault.topUpMinimum(), 1e6);
    }

    /// On mainnet a leftover override from a Sepolia session must stop the deploy, not change fixed terms.
    function test_Run_RevertWhen_MainnetOverriddenFromEnv() public {
        vm.chainId(MAINNET);
        vm.etch(MAINNET_USDT, address(new MockTether()).code);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("SAFE_ADDRESS", vm.toString(safe));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("OPENING_MINIMUM", "1000000000");
        vm.expectRevert(Deploy.MainnetSettingsAreFixed.selector);
        script.run();
    }

    function test_DeployTestTether_SepoliaOnly() public {
        DeployTestTether tokenScript = new DeployTestTether();
        vm.chainId(MAINNET);
        vm.expectRevert(abi.encodeWithSelector(DeployTestTether.SepoliaOnly.selector, MAINNET));
        tokenScript.run();

        vm.chainId(SEPOLIA);
        TestTether token = tokenScript.run();
        assertEq(token.decimals(), 6);
    }
}
