// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";
import {ITAGITTreasury} from "../../src/interfaces/ITAGITTreasury.sol";

// Simple mock ERC20 for testing
contract MockTokenP11 is ERC20 {
    constructor() ERC20("TAGIT", "TAG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title Patch11TreasuryAssetTest
 * @notice Tests for PATCH-11: asset type lock on treasury allocations
 */
contract Patch11TreasuryAssetTest is Test {
    TAGITTreasury public treasury;
    MockTokenP11 public tagitToken;

    address public governor = makeAddr("governor");
    address public recipient = makeAddr("recipient");
    address public attacker = makeAddr("attacker");

    address[] public signers;

    function setUp() public {
        tagitToken = new MockTokenP11();

        // Create 8 signers
        for (uint256 i = 0; i < 8; i++) {
            signers.push(makeAddr(string(abi.encodePacked("signer", i))));
        }

        // Deploy treasury via proxy
        TAGITTreasury treasuryImpl = new TAGITTreasury();
        bytes memory initData = abi.encodeCall(
            TAGITTreasury.initialize,
            (governor, address(tagitToken), signers)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(treasuryImpl), initData);
        treasury = TAGITTreasury(payable(address(proxy)));

        // Fund treasury with TAGIT tokens
        tagitToken.mint(address(treasury), 1_000_000e18);

        // Also fund with ETH
        vm.deal(address(treasury), 100 ether);

        // Sync drain detector
        vm.prank(governor);
        treasury.syncDrainDetectorBalance();
    }

    function test_queueWithdrawal_correct_asset_succeeds() public {
        // Create allocation
        vm.prank(governor);
        uint256 allocId = treasury.createAllocation(
            keccak256("GRANTS"),
            10_000e18,
            recipient,
            uint48(365 days)
        );

        // Queue withdrawal with TAGIT token — should succeed
        vm.prank(recipient);
        uint256 wId = treasury.queueWithdrawal(allocId, address(tagitToken), 5_000e18, recipient);
        assertTrue(wId > 0, "Withdrawal should be queued");
    }

    function test_queueWithdrawal_wrong_asset_reverts() public {
        // Create allocation (implicitly for TAGIT)
        vm.prank(governor);
        uint256 allocId = treasury.createAllocation(
            keccak256("GRANTS"),
            10_000e18,
            recipient,
            uint48(365 days)
        );

        // Try to withdraw ETH using TAGIT allocation — must revert
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITTreasury.AssetMismatch.selector,
            address(tagitToken),
            address(0)
        ));
        treasury.queueWithdrawal(allocId, address(0), 10_000e18, recipient);
    }

    function test_queueWithdrawal_random_token_reverts() public {
        MockTokenP11 otherToken = new MockTokenP11();

        vm.prank(governor);
        uint256 allocId = treasury.createAllocation(
            keccak256("GRANTS"),
            10_000e18,
            recipient,
            uint48(365 days)
        );

        // Try to withdraw a different ERC20 using TAGIT allocation
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITTreasury.AssetMismatch.selector,
            address(tagitToken),
            address(otherToken)
        ));
        treasury.queueWithdrawal(allocId, address(otherToken), 5_000e18, recipient);
    }

    function testFuzz_queueWithdrawal_asset_mismatch(address wrongToken) public {
        vm.assume(wrongToken != address(tagitToken));

        vm.prank(governor);
        uint256 allocId = treasury.createAllocation(
            keccak256("GRANTS"),
            10_000e18,
            recipient,
            uint48(365 days)
        );

        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITTreasury.AssetMismatch.selector,
            address(tagitToken),
            wrongToken
        ));
        treasury.queueWithdrawal(allocId, wrongToken, 5_000e18, recipient);
    }
}
