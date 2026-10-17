// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WebsiteBuyerBase, WebsiteBuyer, IntakeAccount, IIntake, MockIntake} from "./WebsiteBuyerBase.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract WebsiteBuyerTest is WebsiteBuyerBase {
    event WebsiteRequested(
        bytes32 indexed requestId,
        address indexed buyer,
        address indexed intake,
        address account,
        uint256 ethSpent,
        uint256 imdReceived,
        uint256 price,
        uint256 surplus
    );

    function test_constructorAndExactPoolIdentity() public view {
        assertEq(buyer.owner(), OWNER);
        assertEq(address(buyer.intake()), INTAKE);
        assertFalse(buyer.paused());
        PoolKey memory key = buyer.poolKey();
        assertEq(keccak256(abi.encode(key)), buyer.POOL_ID());
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), IMD);
        assertEq(key.fee, 10_000);
        assertEq(key.tickSpacing, 200);
        assertEq(address(key.hooks), address(0));
        assertEq(buyer.JOB_OPEN(), 0x6a6f622e6f70656e406a6f622d31000000000000000000000000000000000000);
    }

    function test_buysExactBodyThroughOwnPayerAndReturnsEverySurplusToken() public {
        bytes32 id = _buy(alice);
        MockIntake.StoredRequest memory sent = intake.requestOf(id);
        IntakeAccount account = buyer.accountOf(alice);
        assertEq(sent.payer, address(account));
        assertEq(account.hub(), address(buyer));
        assertEq(account.user(), alice);
        assertEq(sent.action, JOB_OPEN);
        assertEq(sent.asset, IMD);
        assertEq(sent.amount, PRICE);
        assertEq(sent.callback.target, address(buyer));
        assertEq(sent.callback.selector, buyer.onIntakeResult.selector);
        assertEq(sent.onFailure, buyer.onIntakeFailure.selector);
        assertEq(
            sent.body,
            bytes('{"objective":"Build a one-page website: a bakery in Lisbon","skill":"build-website","host":true}')
        );
        assertEq(imd.balanceOf(treasury), PRICE);
        assertEq(imd.balanceOf(alice), 1.5 ether);
        assertEq(alice.balance, 99 ether);
        assertEq(MANAGER.balance, 1 ether);
        assertEq(imd.balanceOf(MANAGER), 1_000_000 ether - 2 ether);
        WebsiteBuyer.Request memory record = buyer.requestOf(id);
        assertEq(record.buyer, alice);
        assertEq(record.intake, INTAKE);
        assertEq(record.price, PRICE);
        assertEq(uint8(record.state), uint8(WebsiteBuyer.State.Pending));
        _assertClean(alice);
    }

    function test_swapsAllETHWithCanonicalPoolAndNoHookData() public {
        _buy(alice);
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = manager.lastKey();
        assertEq(keccak256(abi.encode(c0, c1, fee, spacing, hooks)), buyer.POOL_ID());
        (bool zeroForOne, int256 amount, uint160 limit) = manager.lastParams();
        assertTrue(zeroForOne);
        assertEq(amount, -1 ether);
        assertEq(limit, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(manager.lastHookData(), "");
        assertEq(manager.totalSettled(), 1 ether);
    }

    function test_exactPriceNoSurplusTransferRequired() public {
        manager.configure(uint128(PRICE), 10_000);
        imd.configure(alice, false, false, 0);
        _buy(alice);
        assertEq(imd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(treasury), PRICE);
        _assertClean(alice);
    }

    function test_livePriceChangesWithoutAnETHPriceSetting() public {
        _buy(alice);
        intake.setPrice(JOB_OPEN, IMD, 1.75 ether);
        bytes32 id = _buy(alice);
        assertEq(intake.requestOf(id).amount, 1.75 ether);
        assertEq(imd.balanceOf(alice), 1.75 ether);
        assertEq(imd.balanceOf(treasury), 2.25 ether);
        _assertClean(alice);
    }

    function test_repeatBuyerReusesAccountAndOtherBuyerHasDifferentPayer() public {
        bytes32 first = _buy(alice);
        bytes32 second = _buy(alice);
        bytes32 third = _buy(bob);
        assertEq(intake.requestOf(first).payer, intake.requestOf(second).payer);
        assertNotEq(intake.requestOf(first).payer, intake.requestOf(third).payer);
        assertNotEq(first, second);
        bytes32 initHash = keccak256(abi.encodePacked(type(IntakeAccount).creationCode, abi.encode(alice)));
        assertEq(
            address(buyer.accountOf(alice)),
            vm.computeCreate2Address(bytes32(uint256(uint160(alice))), initHash, address(buyer))
        );
        _assertClean(alice);
        _assertClean(bob);
    }

    function testFuzz_conservationAndLivePrice(uint96 ethAmount, uint96 amountOut, uint96 livePrice) public {
        uint256 sent = bound(ethAmount, 1, 100 ether);
        uint128 output = uint128(bound(amountOut, 1, 100_000 ether));
        uint256 price = bound(livePrice, 1, output);
        manager.configure(output, 10_000);
        intake.setPrice(JOB_OPEN, IMD, price);
        vm.prank(alice);
        bytes32 id = buyer.buyWebsite{value: sent}("a museum");
        assertEq(alice.balance, 100 ether - sent);
        assertEq(MANAGER.balance, sent);
        assertEq(imd.balanceOf(alice), output - price);
        assertEq(imd.balanceOf(treasury), price);
        assertEq(imd.balanceOf(MANAGER) + imd.balanceOf(alice) + imd.balanceOf(treasury), 1_000_000 ether);
        assertEq(buyer.requestOf(id).price, price);
        _assertClean(alice);
    }

    function test_unpricedRevertsBeforeAnySwap() public {
        intake.setPrice(JOB_OPEN, IMD, 0);
        vm.expectRevert(WebsiteBuyer.ActionNotSold.selector);
        _buy(alice);
        assertEq(manager.swaps(), 0);
        assertEq(alice.balance, 100 ether);
        assertEq(address(buyer.accountOf(alice)), address(0));
    }

    function test_belowPriceRevertsEntireSwapEvenWithDonatedIMD() public {
        imd.mint(address(buyer), 10 ether);
        manager.configure(uint128(PRICE - 1), 10_000);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.InsufficientIMD.selector, PRICE - 1, PRICE));
        _buy(alice);
        assertEq(manager.swaps(), 0);
        assertEq(MANAGER.balance, 0);
        assertEq(alice.balance, 100 ether);
        assertEq(imd.balanceOf(address(buyer)), 10 ether);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(intake.nonce(), 0);
    }

    function testFuzz_shortOutputAlwaysReverts(uint128 amount) public {
        uint128 output = uint128(bound(amount, 1, PRICE - 1));
        manager.configure(output, 10_000);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.InsufficientIMD.selector, output, PRICE));
        _buy(alice);
        assertEq(alice.balance, 100 ether);
        _assertClean(alice);
    }

    function test_partialFillAndZeroOutputRevert() public {
        manager.configure(2 ether, 9999);
        vm.expectRevert(WebsiteBuyer.IncompleteSwap.selector);
        _buy(alice);
        manager.configure(0, 10_000);
        vm.expectRevert(WebsiteBuyer.IncompleteSwap.selector);
        _buy(alice);
        assertEq(manager.swaps(), 0);
        assertEq(alice.balance, 100 ether);
    }

    function test_missingOrRepeatedUnlockCallbackReverts() public {
        manager.configureFaults(false, true, false);
        vm.expectRevert(WebsiteBuyer.UnexpectedUnlock.selector);
        _buy(alice);
        manager.configureFaults(false, false, true);
        vm.expectRevert(WebsiteBuyer.UnexpectedUnlock.selector);
        _buy(alice);
        assertEq(MANAGER.balance, 0);
    }

    function test_unlockOnlyFromManagerDuringPurchase() public {
        vm.expectRevert(WebsiteBuyer.UnexpectedUnlock.selector);
        buyer.unlockCallback(abi.encode(uint256(1 ether)));
        vm.prank(MANAGER);
        vm.expectRevert(WebsiteBuyer.UnexpectedUnlock.selector);
        buyer.unlockCallback("");
        _buy(alice);
        vm.prank(MANAGER);
        vm.expectRevert(WebsiteBuyer.UnexpectedUnlock.selector);
        buyer.unlockCallback("");
    }

    function test_shortTokenDeliveryDetected() public {
        manager.configureFaults(true, false, false);
        vm.expectRevert(WebsiteBuyer.UnexpectedTokenBalance.selector);
        _buy(alice);
        assertEq(imd.balanceOf(treasury), 0);
    }

    function test_feeOnTransferRejected() public {
        imd.configure(address(0), false, false, 1);
        vm.expectRevert(WebsiteBuyer.UnexpectedTokenBalance.selector);
        _buy(alice);
        assertEq(alice.balance, 100 ether);
    }

    function test_tokensWithEmptyReturnDataWork() public {
        imd.configure(address(0), false, true, 0);
        _buy(alice);
        assertEq(imd.balanceOf(alice), 1.5 ether);
        _assertClean(alice);
    }

    function test_failedRefundRollsBackRequestPaymentAndAccountDeployment() public {
        imd.configure(alice, false, false, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        _buy(alice);
        assertEq(intake.nonce(), 0);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(MANAGER.balance, 0);
        assertEq(alice.balance, 100 ether);
        assertEq(address(buyer.accountOf(alice)), address(0));
    }

    function test_failedApprovalAndTreasuryTransferRollBack() public {
        imd.configure(address(0), true, false, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        _buy(alice);
        imd.configure(treasury, false, false, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        _buy(alice);
        assertEq(intake.nonce(), 0);
        assertEq(alice.balance, 100 ether);
    }

    function test_intakeRevertAndMissingPaymentRollBack() public {
        intake.configureFaults(true, false);
        vm.expectRevert(MockIntake.RequestRejected.selector);
        _buy(alice);
        intake.configureFaults(false, true);
        vm.expectRevert(IntakeAccount.PaymentNotConsumed.selector);
        _buy(alice);
        assertEq(intake.nonce(), 0);
        assertEq(alice.balance, 100 ether);
        _assertClean(alice);
    }

    function test_duplicateRequestCannotOverwriteAnotherBuyer() public {
        bytes32 id = _buy(alice);
        intake.setFixedId(id);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.DuplicateRequest.selector, id));
        _buy(bob);
        assertEq(buyer.requestOf(id).buyer, alice);
        assertEq(imd.balanceOf(treasury), PRICE);
        assertEq(bob.balance, 100 ether);
        assertEq(address(buyer.accountOf(bob)), address(0));
    }

    function test_tokenAndIntakeCannotReenterPurchase() public {
        vm.deal(IMD, 1);
        imd.configureReentry(address(buyer), abi.encodeCall(buyer.buyWebsite, ("nested")));
        vm.deal(INTAKE, 1);
        intake.setReentry(address(buyer));
        _buy(alice);
        assertTrue(imd.reentryAttempted());
        assertFalse(imd.reentrySucceeded());
        assertEq(imd.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertTrue(intake.reentryAttempted());
        assertFalse(intake.reentrySucceeded());
        assertEq(intake.nonce(), 1);
        _assertClean(alice);
    }

    function test_noDirectETHDeposits() public {
        vm.prank(alice);
        (bool ok,) = address(buyer).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(buyer).balance, 0);
    }

    function test_zeroAndUnrepresentableETHRejected() public {
        vm.expectRevert(WebsiteBuyer.InvalidETHAmount.selector);
        buyer.buyWebsite("a site");
        uint256 tooBig = uint256(uint128(type(int128).max)) + 1;
        vm.deal(alice, tooBig);
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.InvalidETHAmount.selector);
        buyer.buyWebsite{value: tooBig}("a site");
    }

    function test_onlyOwnerCanPauseAndChangeIntake() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        buyer.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        buyer.setIntake(IIntake(INTAKE));
        vm.stopPrank();
        vm.prank(OWNER);
        buyer.setPaused(true);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _buy(alice);
        vm.prank(OWNER);
        buyer.setPaused(false);
        _buy(alice);
    }

    function test_invalidIntakeAddressesRejected() public {
        address[4] memory invalid = [address(0), alice, address(buyer), IMD];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(OWNER);
            vm.expectRevert(WebsiteBuyer.InvalidIntake.selector);
            buyer.setIntake(IIntake(invalid[i]));
        }
        assertEq(address(buyer.intake()), INTAKE);
    }

    function test_ownershipHandoverRequiresAcceptance() public {
        vm.prank(OWNER);
        buyer.transferOwnership(alice);
        assertEq(buyer.owner(), OWNER);
        assertEq(buyer.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        buyer.acceptOwnership();
        vm.prank(alice);
        buyer.acceptOwnership();
        assertEq(buyer.owner(), alice);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        buyer.setPaused(true);
        vm.prank(alice);
        buyer.setPaused(true);
    }
}
