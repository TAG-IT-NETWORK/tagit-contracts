// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

import {TAGITPaymaster} from "../../src/account/TAGITPaymaster.sol";
import {ITAGITPaymaster} from "../../src/interfaces/ITAGITPaymaster.sol";

/// @dev Minimal EntryPoint mock: only the deposit accounting the paymaster reads.
contract MockEP {
    mapping(address => uint256) public deposits;

    function depositTo(address a) external payable {
        deposits[a] += msg.value;
    }

    function balanceOf(address a) external view returns (uint256) {
        return deposits[a];
    }

    receive() external payable {}
}

/// @title KI-05 — sponsored-selector offset-bypass regression test
/// @notice `TAGITPaymaster` used to read the inner selector from the fixed index
///         [132:136], assuming the ABI offset word for `execute(...)`'s `bytes`
///         argument was the canonical 0x60. The offset is caller-controlled, so a
///         sponsored decoy selector could be parked at [132:136] while the real
///         unsponsored call was placed where the account's own `execute` decodes
///         it — sponsoring arbitrary calls. The fix reads and bounds-checks the
///         offset the account will read, so the two always agree.
///
///         Built independently of the reporter's attachment, which was not run.
contract KI05SelectorOffsetBypassTest is Test {
    TAGITPaymaster internal paymaster;
    MockEP internal ep;

    address internal governor = makeAddr("governor");
    address internal owner = makeAddr("owner");
    address internal attacker = makeAddr("attacker");
    address internal victimTarget = makeAddr("victimTarget");

    bytes4 internal constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));
    bytes4 internal constant SPONSORED = bytes4(keccak256("mint(address,bytes32)")); // decoy / on the allowlist
    bytes4 internal constant UNSPONSORED = bytes4(keccak256("drain()")); // the real call, NOT on the allowlist

    function setUp() public {
        vm.startPrank(owner);
        ep = new MockEP();
        vm.deal(address(ep), 1000 ether);
        TAGITPaymaster impl = new TAGITPaymaster();
        bytes memory initData = abi.encodeCall(TAGITPaymaster.initialize, (address(ep), governor, owner));
        paymaster = TAGITPaymaster(payable(address(new ERC1967Proxy(address(impl), initData))));
        vm.stopPrank();

        vm.startPrank(governor);
        // Only mint(address,bytes32) is sponsored. drain() is not.
        paymaster.setSponsorshipConfig(
            SPONSORED,
            ITAGITPaymaster.SponsorshipConfig({selector: SPONSORED, maxGas: 1_000_000, dailyLimit: 0, active: true})
        );
        vm.stopPrank();

        ep.depositTo{value: 10 ether}(address(paymaster));
        vm.txGasPrice(1 gwei);
    }

    function _op(bytes memory callData) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: attacker,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(uint256(500_000) << 128 | uint256(500_000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: "",
            signature: ""
        });
    }

    /// @dev Canonical ABI encoding of execute(target, 0, <selector bytes>): offset word = 0x60.
    function _canonical(bytes4 innerSelector) internal view returns (bytes memory) {
        return abi.encodeWithSelector(EXECUTE_SELECTOR, victimTarget, uint256(0), abi.encodePacked(innerSelector));
    }

    /// @dev Crafted calldata: offset word = 0xA0, sponsored decoy parked at [132:136],
    ///      real unsponsored inner call placed where the account's ABI decoder reads it.
    function _crafted() internal view returns (bytes memory) {
        return abi.encodePacked(
            EXECUTE_SELECTOR, //                        [0:4]    execute
            bytes32(uint256(uint160(victimTarget))), // [4:36]   dest
            bytes32(uint256(0)), //                     [36:68]  value
            bytes32(uint256(0xA0)), //                  [68:100] offset = 160 (non-canonical)
            bytes32(uint256(0)), //                     [100:132] canonical length slot (ignored at this offset)
            bytes32(SPONSORED), //                      [132:164] DECOY sponsored selector in first 4 bytes
            bytes32(uint256(4)), //                     [164:196] real length = 4
            bytes32(UNSPONSORED) //                     [196:228] real inner call = unsponsored selector
        );
    }

    // ---------------------------------------------------------------------
    // Structural: the crafted calldata really routes to the unsponsored call,
    // with a different (sponsored) selector sitting at the old fixed index.
    // ---------------------------------------------------------------------
    function test_craftedCalldata_decodesToUnsponsoredCall() public view {
        bytes memory cd = _crafted();
        (address dest,, bytes memory func) = abi.decode(_slice4(cd), (address, uint256, bytes));
        assertEq(dest, victimTarget, "dest");
        assertEq(bytes4(func), UNSPONSORED, "account's ABI decoder reads the UNSPONSORED selector");
        assertEq(bytes4(_at(cd, 132)), SPONSORED, "decoy at the old fixed index [132:136] is the sponsored selector");
    }

    // ---------------------------------------------------------------------
    // FIX: the crafted offset no longer bypasses the allowlist — the paymaster
    // now reads the real inner selector (drain) and refuses it.
    // ---------------------------------------------------------------------
    function test_fix_craftedOffsetIsRefused() public {
        vm.prank(address(ep));
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.OperationNotSponsored.selector, UNSPONSORED));
        paymaster.validatePaymasterUserOp(_op(_crafted()), keccak256("hash"), 0.0001 ether);
    }

    // ---------------------------------------------------------------------
    // CONTROL: the unsponsored selector at the canonical offset is refused too
    // (it always was). Confirms the fix did not rely on the offset value.
    // ---------------------------------------------------------------------
    function test_control_canonicalUnsponsored_isRefused() public {
        vm.prank(address(ep));
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.OperationNotSponsored.selector, UNSPONSORED));
        paymaster.validatePaymasterUserOp(_op(_canonical(UNSPONSORED)), keccak256("hash"), 0.0001 ether);
    }

    // ---------------------------------------------------------------------
    // HAPPY PATH: a genuine sponsored call still validates after the fix.
    // ---------------------------------------------------------------------
    function test_fix_canonicalSponsored_stillValidates() public {
        vm.prank(address(ep));
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(_op(_canonical(SPONSORED)), keccak256("hash"), 0.0001 ether);
        assertEq(validationData, 0, "legitimate sponsored call must still validate");
        (, bytes4 ctxSelector,,) = abi.decode(context, (address, bytes4, bytes32, uint256));
        assertEq(ctxSelector, SPONSORED, "context names the sponsored selector");
    }

    // ---------------------------------------------------------------------
    // The non-canonical offset is honoured when the inner call is genuinely
    // sponsored: a sponsored call encoded with offset 0xA0 still validates, and
    // the context names the real selector (not whatever sits at [132:136]).
    // ---------------------------------------------------------------------
    function test_fix_nonCanonicalSponsored_validatesOnRealSelector() public {
        bytes memory cd = abi.encodePacked(
            EXECUTE_SELECTOR,
            bytes32(uint256(uint160(victimTarget))),
            bytes32(uint256(0)),
            bytes32(uint256(0xA0)), // non-canonical offset
            bytes32(uint256(0)),
            bytes32(UNSPONSORED), // junk at the old fixed index
            bytes32(uint256(4)),
            bytes32(SPONSORED) // real inner call IS sponsored
        );
        vm.prank(address(ep));
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(_op(cd), keccak256("hash"), 0.0001 ether);
        assertEq(validationData, 0, "sponsored inner call at a non-canonical offset still validates");
        (, bytes4 ctxSelector,,) = abi.decode(context, (address, bytes4, bytes32, uint256));
        assertEq(ctxSelector, SPONSORED, "context names the REAL inner selector, not the fixed-index bytes");
    }

    // helpers
    function _slice4(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i = 4; i < b.length; i++) {
            out[i - 4] = b[i];
        }
    }

    function _at(bytes memory b, uint256 off) internal pure returns (bytes4 s) {
        assembly {
            s := mload(add(add(b, 0x20), off))
        }
    }
}
