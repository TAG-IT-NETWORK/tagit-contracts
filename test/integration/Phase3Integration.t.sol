// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {wTAG} from "../../src/token/wTAG.sol";
import {Voucher} from "../../src/token/Voucher.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITGovernor} from "../../src/governance/TAGITGovernor.sol";
import {TAGITStaking} from "../../src/token/TAGITStaking.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ITAGITGovernor} from "../../src/interfaces/ITAGITGovernor.sol";

/**
 * @title Phase3IntegrationTest
 * @notice Integration tests for wTAG + Voucher + TAGITGovernor full flow
 */
contract Phase3IntegrationTest is Test {
    // Contracts
    wTAG public wtag;
    Voucher public voucher;
    TAGITToken public tagitToken;
    TAGITGovernor public governor;
    TAGITStaking public staking;
    TAGITAccess public access;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;
    TimelockController public timelock;

    // Actors
    address public owner;
    address public treasury;
    address public guardian;
    address public coreContract;
    address public proposer;
    address public publicVoter;

    // Constants
    uint256 public constant STAKE_AMOUNT = 150_000e18;
    uint256 public constant VOUCHER_AMOUNT = 1000e18;

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        guardian = makeAddr("guardian");
        coreContract = makeAddr("coreContract");
        proposer = makeAddr("proposer");
        publicVoter = makeAddr("publicVoter");

        vm.startPrank(owner);

        // 1. Deploy TAGIT token
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(TAGITToken.initialize, (treasury, owner));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        tagitToken = TAGITToken(address(tokenProxy));

        // 2. Deploy wTAG
        wTAG wtagImpl = new wTAG();
        bytes memory wtagData = abi.encodeCall(wTAG.initialize, (address(tagitToken), owner));
        ERC1967Proxy wtagProxy = new ERC1967Proxy(address(wtagImpl), wtagData);
        wtag = wTAG(address(wtagProxy));

        // 3. Deploy Identity & Capability badges (not upgradeable)
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        access = new TAGITAccess();
        access.setIdentityBadge(address(identityBadge));
        access.setCapabilityBadge(address(capabilityBadge));

        // 4. Deploy Staking (upgradeable)
        TAGITStaking stakingImpl = new TAGITStaking();
        staking = TAGITStaking(
            address(
                new ERC1967Proxy(
                    address(stakingImpl), abi.encodeCall(TAGITStaking.initialize, (address(tagitToken), owner, owner))
                )
            )
        );

        // 5. Deploy Timelock (non-upgradeable)
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0); // Will be set to governor
        executors[0] = address(0); // Open executor

        timelock = new TimelockController(2 days, proposers, executors, owner);

        // 6. Deploy Governor with wTAG as IVotes token
        TAGITGovernor govImpl = new TAGITGovernor();
        governor = TAGITGovernor(
            payable(address(
                    new ERC1967Proxy(
                        address(govImpl),
                        abi.encodeCall(
                            TAGITGovernor.initialize,
                            (
                                IVotes(address(wtag)),
                                TimelockControllerUpgradeable(payable(address(timelock))),
                                access,
                                staking,
                                guardian,
                                owner
                            )
                        )
                    )
                ))
        );

        // Grant timelock roles to governor
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // 7. Deploy Voucher
        Voucher voucherImpl = new Voucher();
        voucher = Voucher(
            address(
                new ERC1967Proxy(
                    address(voucherImpl),
                    abi.encodeCall(Voucher.initialize, (coreContract, address(wtag), owner, 10000))
                )
            )
        );

        // 8. Grant MINTER_ROLE on wTAG to coreContract and Voucher
        wtag.grantMinter(coreContract);
        wtag.grantMinter(address(voucher));

        vm.stopPrank();

        // 9. Distribute TAGIT tokens from treasury and setup proposer staking
        vm.prank(treasury);
        tagitToken.transfer(proposer, STAKE_AMOUNT);

        vm.startPrank(proposer);
        tagitToken.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();
    }

    // ============================================
    // INTEGRATION: Voucher → Redeem → wTAG → Delegate → Voting Power
    // ============================================

    function test_fullVoucherRedemptionFlow() public {
        // Step 1: TAGITCore issues voucher to user
        vm.prank(coreContract);
        voucher.issue(publicVoter, VOUCHER_AMOUNT, 42, "activation");
        assertEq(voucher.balanceOf(publicVoter), VOUCHER_AMOUNT);

        // Step 2: User redeems voucher for wTAG
        vm.prank(publicVoter);
        uint256 wtagReceived = voucher.redeem(VOUCHER_AMOUNT);
        assertEq(wtagReceived, VOUCHER_AMOUNT);
        assertEq(wtag.balanceOf(publicVoter), VOUCHER_AMOUNT);
        assertEq(voucher.balanceOf(publicVoter), 0);

        // Step 3: User delegates wTAG to self for governance
        vm.prank(publicVoter);
        wtag.delegate(publicVoter);
        assertEq(wtag.getVotes(publicVoter), VOUCHER_AMOUNT);
    }

    // ============================================
    // INTEGRATION: wTAG IVotes in Governor
    // ============================================

    function test_wtagVotingPowerInGovernor() public {
        // Give publicVoter wTAG and delegate
        vm.prank(coreContract);
        wtag.mint(publicVoter, 10_000e18);

        vm.prank(publicVoter);
        wtag.delegate(publicVoter);

        // Verify governor sees voting power through wTAG
        (uint256 weight, ITAGITGovernor.House house) = governor.getVotingPower(publicVoter);
        assertEq(weight, 10_000e18);
        assertEq(uint256(house), uint256(ITAGITGovernor.House.PUBLIC));
    }

    // ============================================
    // INTEGRATION: VoucherProposal — governance changes redemption rate
    // ============================================

    function test_voucherProposal_setRedemptionRate() public {
        // Give proposer wTAG voting power (needs both staked + wTAG)
        vm.prank(coreContract);
        wtag.mint(proposer, 1_000_000e18);

        vm.prank(proposer);
        wtag.delegate(proposer);

        // Advance block so delegation checkpoint is historical
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        // Create proposal to change voucher redemption rate to 50%
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(voucher);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(Voucher.setRedemptionRate, (5000));

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, "VoucherProposal: reduce rate to 50%");

        assertTrue(proposalId > 0);
    }

    // ============================================
    // INTEGRATION: Multiple issuances accumulate
    // ============================================

    function test_multipleVoucherIssuances() public {
        vm.startPrank(coreContract);
        voucher.issue(publicVoter, 100e18, 1, "activation");
        voucher.issue(publicVoter, 200e18, 2, "activation");
        voucher.issue(publicVoter, 50e18, 3, "claim");
        vm.stopPrank();

        assertEq(voucher.balanceOf(publicVoter), 350e18);

        vm.prank(publicVoter);
        uint256 wtagReceived = voucher.redeem(350e18);

        assertEq(wtagReceived, 350e18);
        assertEq(wtag.balanceOf(publicVoter), 350e18);
    }

    // ============================================
    // INTEGRATION: Wrap TAGIT → wTAG → delegate → governance power
    // ============================================

    function test_wrapTagitAndGovern() public {
        uint256 wrapAmount = 5000e18;
        vm.prank(treasury);
        tagitToken.transfer(publicVoter, wrapAmount);

        vm.startPrank(publicVoter);
        tagitToken.approve(address(wtag), wrapAmount);
        wtag.wrap(wrapAmount);
        wtag.delegate(publicVoter);
        vm.stopPrank();

        assertEq(wtag.getVotes(publicVoter), wrapAmount);
        (uint256 weight, ITAGITGovernor.House house) = governor.getVotingPower(publicVoter);
        assertEq(weight, wrapAmount);
        assertEq(uint256(house), uint256(ITAGITGovernor.House.PUBLIC));
    }

    // ============================================
    // INTEGRATION: wTAG quorum calculation uses totalSupply
    // ============================================

    function test_quorumBasedOnWtagSupply() public {
        // Mint some wTAG to create supply
        vm.prank(coreContract);
        wtag.mint(publicVoter, 1_000_000e18);

        vm.prank(publicVoter);
        wtag.delegate(publicVoter);

        // Advance a block for checkpoint
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        // Quorum = 4% of totalSupply = 40,000e18
        uint256 expectedQuorum = (wtag.totalSupply() * 400) / 10000;
        uint256 actualQuorum = governor.quorum(block.timestamp - 1);
        assertEq(actualQuorum, expectedQuorum);
    }
}
