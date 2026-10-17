// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WebsiteBuyerBase, WebsiteBuyer, MockIntake, IIntake} from "./WebsiteBuyerBase.t.sol";

contract WebsiteCallbacksTest is WebsiteBuyerBase {
    event WebsiteResult(bytes32 indexed requestId, address indexed buyer, bytes32 resultHash, string uri);
    event WebsiteFailure(bytes32 indexed requestId, address indexed buyer, uint8 status, bytes32 reason);

    function test_resultStoredAndEmittedWithin200000Gas() public {
        bytes32 id = _buy(alice);
        bytes32 hash = keccak256("canonical result JSON");
        vm.expectEmit(true, true, false, true, address(buyer));
        emit WebsiteResult(id, alice, hash, URI);
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, abi.encode(id, hash, URI)));
        WebsiteBuyer.Request memory request = buyer.requestOf(id);
        assertEq(request.buyer, alice);
        assertEq(uint8(request.state), uint8(WebsiteBuyer.State.Done));
        assertEq(request.resultHash, hash);
        assertEq(request.uri, URI);
        assertEq(request.reason, bytes32(0));
        assertEq(imd.balanceOf(treasury), PRICE);
        _assertClean(alice);
    }

    function test_refusalAndFailureStoredAndEmittedWithin200000Gas() public {
        for (uint8 status = 1; status <= 2; ++status) {
            bytes32 id = _buy(alice);
            bytes32 reason = status == 1 ? bytes32("admission_refused") : bytes32("blocked");
            uint256 buyerBalance = imd.balanceOf(alice);
            vm.expectEmit(true, true, false, true, address(buyer));
            emit WebsiteFailure(id, alice, status, reason);
            vm.prank(writer);
            assertTrue(intake.complete(id, status, abi.encode(id, status, reason, uint16(0), uint16(0), bytes(""))));
            WebsiteBuyer.Request memory request = buyer.requestOf(id);
            assertEq(uint8(request.state), uint8(WebsiteBuyer.State.Failed));
            assertEq(request.status, status);
            assertEq(request.reason, reason);
            assertEq(request.resultHash, bytes32(0));
            assertEq(request.uri, "");
            assertEq(imd.balanceOf(alice), buyerBalance);
            assertEq(imd.balanceOf(treasury), PRICE * status);
        }
        _assertClean(alice);
    }

    function test_wrongSenderAndUnknownRequestsRejectedOnBothCallbacks() public {
        bytes32 id = _buy(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
        buyer.onIntakeResult(id, keccak256("fake"), "fake");
        vm.prank(writer); // writer must go through the Intake
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
        buyer.onIntakeFailure(id, 1, bytes32("refused"), 0, 0, "");
        bytes32 unknown = keccak256("someone else's request naming this callback");
        vm.startPrank(INTAKE);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, unknown));
        buyer.onIntakeResult(unknown, bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, unknown));
        buyer.onIntakeFailure(unknown, 1, bytes32("refused"), 0, 0, "");
        vm.stopPrank();
        assertEq(uint8(buyer.requestOf(id).state), uint8(WebsiteBuyer.State.Pending));
    }

    function test_resultCannotBeOverwrittenByEitherCallback() public {
        bytes32 id = _buy(alice);
        vm.startPrank(INTAKE);
        buyer.onIntakeResult(id, keccak256("good"), URI);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
        buyer.onIntakeResult(id, keccak256("bad"), "fake");
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
        buyer.onIntakeFailure(id, 1, bytes32("refused"), 0, 0, "");
        vm.stopPrank();
        assertEq(buyer.requestOf(id).resultHash, keccak256("good"));
        assertEq(buyer.requestOf(id).uri, URI);
    }

    function test_failureCannotBeOverwrittenByEitherCallback() public {
        bytes32 id = _buy(alice);
        vm.startPrank(INTAKE);
        buyer.onIntakeFailure(id, 2, bytes32("failed"), 0, 0, "");
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
        buyer.onIntakeFailure(id, 1, bytes32("refused"), 0, 0, "");
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, id));
        buyer.onIntakeResult(id, bytes32(0), "");
        vm.stopPrank();
        assertEq(buyer.requestOf(id).reason, bytes32("failed"));
        assertEq(buyer.requestOf(id).status, 2);
    }

    function test_failureRejectsStatusZero() public {
        bytes32 id = _buy(alice);
        vm.prank(INTAKE);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.InvalidFailureStatus.selector, uint8(0)));
        buyer.onIntakeFailure(id, 0, bytes32("refused"), 0, 0, "");
        assertEq(uint8(buyer.requestOf(id).state), uint8(WebsiteBuyer.State.Pending));
    }

    function testFuzz_anyNonzeroFailureStatusIsRecorded(uint8 rawStatus) public {
        uint8 status = uint8(bound(rawStatus, 1, type(uint8).max));
        bytes32 id = _buy(alice);
        vm.expectEmit(true, true, false, true, address(buyer));
        emit WebsiteFailure(id, alice, status, bytes32("expired"));
        vm.prank(writer);
        assertTrue(
            intake.complete(id, status, abi.encode(id, status, bytes32("expired"), uint16(0), uint16(0), bytes("")))
        );
        WebsiteBuyer.Request memory request = buyer.requestOf(id);
        assertEq(uint8(request.state), uint8(WebsiteBuyer.State.Failed));
        assertEq(request.status, status);
        assertEq(request.reason, bytes32("expired"));
    }

    function test_uriAtStorageLimitIsStored() public {
        bytes32 id = _buy(alice);
        string memory uri = _repeat(buyer.MAX_STORED_URI_BYTES(), "u");
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, abi.encode(id, keccak256("r"), uri)));
        assertEq(uint8(buyer.requestOf(id).state), uint8(WebsiteBuyer.State.Done));
        assertEq(buyer.requestOf(id).uri, uri);
    }

    function test_longUriStillSettlesWithHashAndIsEmittedNotStored() public {
        bytes32 id = _buy(alice);
        string memory uri = _repeat(4096, "u");
        bytes32 hash = keccak256("r");
        vm.expectEmit(true, true, false, true, address(buyer));
        emit WebsiteResult(id, alice, hash, uri);
        vm.prank(writer);
        assertTrue(intake.complete(id, 0, abi.encode(id, hash, uri)));
        WebsiteBuyer.Request memory request = buyer.requestOf(id);
        assertEq(uint8(request.state), uint8(WebsiteBuyer.State.Done));
        assertEq(request.resultHash, hash);
        assertEq(request.uri, "");
        _assertClean(alice);
    }

    function test_intakeMigrationKeepsOldAndNewCallbacksSeparate() public {
        bytes32 oldId = _buy(alice);
        MockIntake next = new MockIntake();
        next.configure(treasury, writer, JOB_OPEN, IMD, 0.75 ether);
        vm.prank(OWNER);
        buyer.setIntake(IIntake(address(next)));
        bytes32 newId = _buy(alice);
        assertEq(next.requestOf(newId).amount, 0.75 ether);
        assertEq(next.requestOf(newId).payer, intake.requestOf(oldId).payer);
        vm.prank(address(next));
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, oldId));
        buyer.onIntakeResult(oldId, bytes32(0), "wrong intake");
        vm.prank(INTAKE);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.NotPending.selector, newId));
        buyer.onIntakeFailure(newId, 1, bytes32("refused"), 0, 0, "");
        vm.prank(writer);
        assertTrue(intake.complete(oldId, 0, abi.encode(oldId, keccak256("result"), URI)));
        vm.prank(writer);
        assertTrue(
            next.complete(newId, 2, abi.encode(newId, uint8(2), bytes32("failed"), uint16(0), uint16(0), bytes("")))
        );
        assertEq(imd.allowance(address(buyer.accountOf(alice)), address(next)), 0);
        _assertClean(alice);
    }

    function test_pausedPurchasesDoNotBlockCallbacks() public {
        bytes32 first = _buy(alice);
        bytes32 second = _buy(bob);
        vm.prank(OWNER);
        buyer.setPaused(true);
        vm.startPrank(writer);
        assertTrue(intake.complete(first, 0, abi.encode(first, keccak256("result"), URI)));
        assertTrue(
            intake.complete(
                second, 1, abi.encode(second, uint8(1), bytes32("body_refused"), uint16(0), uint16(0), bytes(""))
            )
        );
        vm.stopPrank();
    }

    function test_missingAndUndeliverableCallbacksDoNotLockFuturePurchases() public {
        bytes32 missing = _buy(alice);
        bytes32 tooLong = _buy(alice);
        // Emitting 32 KiB costs more log gas than the whole 200 000 gas stipend.
        string memory longURI = _repeat(32_768, "u");
        vm.prank(writer);
        assertFalse(intake.complete(tooLong, 0, abi.encode(tooLong, keccak256("result"), longURI)));
        assertTrue(intake.requestOf(tooLong).completed);
        assertFalse(intake.requestOf(tooLong).delivered);
        assertEq(uint8(buyer.requestOf(tooLong).state), uint8(WebsiteBuyer.State.Pending));
        _buy(alice);
        _buy(bob);
        assertEq(uint8(buyer.requestOf(missing).state), uint8(WebsiteBuyer.State.Pending));
        _assertClean(alice);
    }

    function test_mockOnlyWriterCanComplete() public {
        bytes32 id = _buy(alice);
        vm.prank(bob);
        vm.expectRevert(MockIntake.NotWriter.selector);
        intake.complete(id, 0, abi.encode(id, bytes32(0), URI));
    }
}
