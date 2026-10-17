// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WebsiteBuyerBase, WebsiteBuyer, IntakeAccount, MockIntake} from "./WebsiteBuyerBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract WebsiteBuyerEdgesTest is WebsiteBuyerBase {
    function _predictedAccount(address user) internal view returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(IntakeAccount).creationCode, abi.encode(user)));
        return vm.computeCreate2Address(bytes32(uint256(uint160(user))), initHash, address(buyer));
    }

    /// Someone funds a buyer's future account address before the first purchase. The account must
    /// still be created there, spend only the price it was sent, and leave the rest to the buyer.
    function test_prefundedAccountAddressStillOpensAndFundsStayWithBuyer() public {
        address predicted = _predictedAccount(alice);
        imd.mint(predicted, 7 ether);
        vm.deal(predicted, 3 ether);
        bytes32 id = _buy(alice);
        assertEq(address(buyer.accountOf(alice)), predicted);
        assertEq(intake.requestOf(id).payer, predicted);
        assertEq(imd.balanceOf(predicted), 7 ether);
        assertEq(predicted.balance, 3 ether);
        assertEq(imd.allowance(predicted, INTAKE), 0);
        vm.startPrank(alice);
        IntakeAccount(payable(predicted)).execute(IMD, 0, abi.encodeCall(IERC20.transfer, (alice, 7 ether)));
        IntakeAccount(payable(predicted)).execute(alice, 3 ether, "");
        vm.stopPrank();
        _assertClean(alice);
    }

    function test_largestRepresentableETHAmountIsAccepted() public {
        uint256 max = uint256(uint128(type(int128).max));
        vm.deal(alice, max);
        vm.prank(alice);
        bytes32 id = buyer.buyWebsite{value: max}("a very expensive website");
        assertEq(MANAGER.balance, max);
        assertEq(alice.balance, 0);
        assertEq(buyer.requestOf(id).buyer, alice);
        _assertClean(alice);
    }

    function test_oneWeiPurchaseWorksWhenThePoolPaysThePrice() public {
        manager.configure(uint128(PRICE), 10_000);
        vm.prank(alice);
        buyer.buyWebsite{value: 1}("x");
        assertEq(MANAGER.balance, 1);
        assertEq(imd.balanceOf(treasury), PRICE);
        _assertClean(alice);
    }

    function test_pauseTransitionsAreStrictAndPreviewStillWorks() public {
        vm.startPrank(OWNER);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        buyer.setPaused(false);
        buyer.setPaused(true);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        buyer.setPaused(true);
        vm.stopPrank();
        assertEq(
            buyer.bodyOf("paused preview"),
            bytes('{"objective":"Build a one-page website: paused preview","skill":"build-website","host":true}')
        );
        // A paused contract refuses even bad words with the pause, before touching any dependency.
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        buyer.buyWebsite{value: 1 ether}("");
        assertEq(manager.swaps(), 0);
    }

    function test_badWordsRefusedBeforeReadingAnUnsoldPrice() public {
        intake.setPrice(JOB_OPEN, IMD, 0);
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.BadWords.selector);
        buyer.buyWebsite{value: 1 ether}('say "hi"');
    }

    function test_bodyNeverCarriesAnOwnerField() public view {
        bytes memory body = buyer.bodyOf("owner");
        assertEq(body, bytes('{"objective":"Build a one-page website: owner","skill":"build-website","host":true}'));
        // The only key-like run in the template is the four fixed keys.
        assertEq(_count(body, '":'), 3);
    }

    function test_planeFallbackURIIsDeliveredWithinTheStipend() public {
        bytes32 id = _buy(alice);
        string memory uri = string.concat(
            "https://plane.identitymd.example/intake-results/",
            "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        );
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, abi.encode(id, keccak256("doc"), uri)));
        assertEq(buyer.requestOf(id).uri, uri);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_resultURIIsDeliveredStoredUpToCapAndAlwaysEmitted(uint8 lenSeed, bytes32 hash) public {
        uint256 len = bound(lenSeed, 0, 255);
        bytes32 id = _buy(alice);
        string memory uri = _repeat(len, "u");
        vm.expectEmit(true, true, false, true, address(buyer));
        emit WebsiteBuyer.WebsiteResult(id, alice, hash, uri);
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, abi.encode(id, hash, uri)));
        WebsiteBuyer.Request memory request = buyer.requestOf(id);
        assertEq(uint8(request.state), uint8(WebsiteBuyer.State.Done));
        assertEq(request.resultHash, hash);
        assertEq(request.uri, len <= buyer.MAX_STORED_URI_BYTES() ? uri : "");
    }

    function test_resultURIStorageCapBoundary() public {
        uint256 cap = buyer.MAX_STORED_URI_BYTES();
        assertEq(cap, 128);
        bytes32 a = _buy(alice);
        bytes32 b = _buy(bob);
        vm.startPrank(writer);
        assertTrue(intake.complete(a, 0, abi.encode(a, keccak256("a"), _repeat(cap, "a"))));
        assertTrue(intake.complete(b, 0, abi.encode(b, keccak256("b"), _repeat(cap + 1, "b"))));
        vm.stopPrank();
        assertEq(buyer.requestOf(a).uri, _repeat(cap, "a"));
        assertEq(buyer.requestOf(b).uri, "");
        assertEq(buyer.requestOf(b).resultHash, keccak256("b"));
    }

    /// A very long URI is still settled within the 200 000 gas stipend, since it is only emitted.
    function test_veryLongResultURIStillSettles() public {
        bytes32 id = _buy(alice);
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, abi.encode(id, keccak256("long"), _repeat(4096, "l"))));
        assertEq(uint8(buyer.requestOf(id).state), uint8(WebsiteBuyer.State.Done));
    }

    function test_laterNonzeroFailureStatusIsRecorded() public {
        bytes32 id = _buy(alice);
        vm.prank(writer);
        assertTrue(intake.complete(id, 7, abi.encode(id, uint8(7), bytes32("odd"), uint16(0), uint16(0), "")));
        WebsiteBuyer.Request memory request = buyer.requestOf(id);
        assertEq(uint8(request.state), uint8(WebsiteBuyer.State.Failed));
        assertEq(request.status, 7);
        assertEq(request.reason, bytes32("odd"));
    }

    function test_failureWithPanelFieldsAndLongSignatureIsRecordedWithinStipend() public {
        bytes32 id = _buy(alice);
        bytes memory signature = bytes(_repeat(2048, "s"));
        vm.prank(writer);
        assertTrue(intake.complete(id, 2, abi.encode(id, uint8(2), bytes32("failed"), uint16(3), uint16(5), signature)));
        WebsiteBuyer.Request memory request = buyer.requestOf(id);
        assertEq(uint8(request.state), uint8(WebsiteBuyer.State.Failed));
        assertEq(request.status, 2);
        assertEq(request.reason, bytes32("failed"));
    }

    function test_failedDeliveryLeavesRequestPendingAndWriterCannotRetry() public {
        bytes32 id = _buy(alice);
        vm.prank(writer);
        // Status 0 on the failure path is refused by the contract, so the Intake records it undelivered.
        assertFalse(intake.complete(id, 1, abi.encode(id, uint8(0), bytes32("odd"), uint16(0), uint16(0), "")));
        assertEq(uint8(buyer.requestOf(id).state), uint8(WebsiteBuyer.State.Pending));
        vm.prank(writer);
        vm.expectRevert(bytes("not pending"));
        intake.complete(id, 0, abi.encode(id, keccak256("late"), URI));
        assertEq(imd.balanceOf(treasury), PRICE); // the price stays spent
    }

    function test_ownerAndOtherBuyerCannotSpendFromABuyersAccount() public {
        _buy(alice);
        IntakeAccount account = buyer.accountOf(alice);
        imd.mint(address(account), 1 ether);
        address[2] memory outsiders = [OWNER, bob];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(IntakeAccount.NotUser.selector);
            account.execute(IMD, 0, abi.encodeCall(IERC20.transfer, (outsiders[i], 1 ether)));
        }
        // A later purchase by alice does not spend the extra token either.
        _buy(alice);
        assertEq(imd.balanceOf(address(account)), 1 ether);
    }

    function test_requestRecordsTheIntakeTakenNotTheCurrentOne() public {
        bytes32 id = _buy(alice);
        MockIntake next = new MockIntake();
        next.configure(treasury, writer, JOB_OPEN, IMD, PRICE);
        vm.prank(OWNER);
        buyer.setIntake(next);
        assertEq(buyer.requestOf(id).intake, INTAKE);
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, abi.encode(id, keccak256("old intake result"), URI)));
        assertEq(uint8(buyer.requestOf(id).state), uint8(WebsiteBuyer.State.Done));
    }

    function _count(bytes memory data, bytes memory needle) internal pure returns (uint256 n) {
        for (uint256 i; i + needle.length <= data.length; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length; ++j) {
                if (data[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) ++n;
        }
    }
}
