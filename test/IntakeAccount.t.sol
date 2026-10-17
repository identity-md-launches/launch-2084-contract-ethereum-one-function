// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WebsiteBuyerBase, WebsiteBuyer, IntakeAccount, IIntake, MockIntake} from "./WebsiteBuyerBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AccountUser {
    IntakeAccount public account;
    bool public nestedSuccess;
    bytes public nestedError;

    function buy(WebsiteBuyer buyer) external payable {
        buyer.buyWebsite{value: msg.value}("a website for a contract wallet");
        account = buyer.accountOf(address(this));
    }

    function tryReentry() external {
        account.execute(address(this), 0, abi.encodeCall(this.onExecute, ()));
    }

    function onExecute() external {
        (nestedSuccess, nestedError) =
            address(account).call(abi.encodeCall(account.execute, (address(this), 0, bytes(""))));
    }
}

contract IntakeAccountTest is WebsiteBuyerBase {
    function test_onlyHubAsksAndOnlyBuyerExecutes() public {
        _buy(alice);
        IntakeAccount account = buyer.accountOf(alice);
        address[3] memory outsiders = [bob, OWNER, address(buyer)];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(IntakeAccount.NotUser.selector);
            account.execute(bob, 0, "");
        }
        vm.prank(alice);
        vm.expectRevert(IntakeAccount.NotHub.selector);
        account.ask(IIntake(INTAKE), JOB_OPEN, "{}", IIntake.Callback(alice, bytes4(0)), bytes4(0), IMD, PRICE);
    }

    function test_buyerCanUseSamePayerForContinuationOtherBuyerCannot() public {
        bytes32 opened = _buy(alice);
        _buy(bob);
        bytes32 project = keccak256("project id from the result document");
        vm.prank(writer);
        intake.registerProject(project, opened);

        // The body is the off-chain job's actual UUID in production. The mock models payer admission.
        bytes memory continuation = bytes(
            '{"parentJobId":"8a4f2c1e-3b5d-4e6f-9a7b-1c2d3e4f5a6b","objective":"Add a dark mode toggle.","skill":"build-website","host":true}'
        );
        bytes32 aliceContinue = _continue(alice, continuation);
        bytes32 bobContinue = _continue(bob, continuation);
        vm.startPrank(writer);
        assertTrue(intake.admitContinuation(aliceContinue, project));
        assertFalse(intake.admitContinuation(bobContinue, project));
        vm.stopPrank();
        assertEq(intake.requestOf(aliceContinue).payer, intake.requestOf(opened).payer);
        assertNotEq(intake.requestOf(bobContinue).payer, intake.requestOf(opened).payer);
        assertEq(imd.balanceOf(treasury), 4 * PRICE); // Even the other payer's refusal is spent.
        _assertClean(alice);
        _assertClean(bob);
    }

    function test_pauseDoesNotTakeAwayBuyerControlOfPayer() public {
        _buy(alice);
        IntakeAccount account = buyer.accountOf(alice);
        vm.prank(OWNER);
        buyer.setPaused(true);
        imd.mint(address(account), 3 ether);
        vm.deal(address(account), 2 ether);
        uint256 before = alice.balance;
        vm.startPrank(alice);
        account.execute(alice, 2 ether, "");
        account.execute(IMD, 0, abi.encodeCall(IERC20.transfer, (alice, 3 ether)));
        vm.stopPrank();
        assertEq(alice.balance, before + 2 ether);
        assertEq(imd.balanceOf(alice), 4.5 ether);
        _assertClean(alice);
    }

    function test_payableExecuteAndReturnDataAndRevertBubbling() public {
        _buy(alice);
        IntakeAccount account = buyer.accountOf(alice);
        vm.prank(alice);
        account.execute{value: 1 ether}(bob, 1 ether, "");
        assertEq(bob.balance, 101 ether);
        vm.prank(alice);
        bytes memory result = account.execute(IMD, 0, abi.encodeCall(IERC20.balanceOf, (alice)));
        assertEq(abi.decode(result, (uint256)), 1.5 ether);
        vm.prank(alice);
        vm.expectRevert(MockIntake.NotWriter.selector);
        account.execute(INTAKE, 0, abi.encodeCall(intake.complete, (bytes32(0), uint8(0), bytes(""))));
    }

    function test_contractBuyerGetsSurplusWithoutAnETHReceiveFunction() public {
        AccountUser user = new AccountUser();
        vm.deal(address(this), 1 ether);
        user.buy{value: 1 ether}(buyer);
        assertEq(imd.balanceOf(address(user)), 1.5 ether);
        assertEq(user.account().user(), address(user));
        _assertClean(address(user));
    }

    function test_userCannotReenterOwnAccountExecution() public {
        AccountUser user = new AccountUser();
        vm.deal(address(this), 1 ether);
        user.buy{value: 1 ether}(buyer);
        user.tryReentry();
        assertFalse(user.nestedSuccess());
        assertEq(user.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function test_existingBuyerFundsInAccountAreNotSpentByNewPurchase() public {
        _buy(alice);
        IntakeAccount account = buyer.accountOf(alice);
        imd.mint(address(account), 10 ether);
        _buy(alice);
        assertEq(imd.balanceOf(address(account)), 10 ether);
        assertEq(imd.allowance(address(account), INTAKE), 0);
        assertEq(imd.balanceOf(treasury), 2 * PRICE);
    }

    function test_accountRejectsZeroUser() public {
        vm.expectRevert(IntakeAccount.InvalidUser.selector);
        new IntakeAccount(address(0));
    }

    function _continue(address user, bytes memory body) private returns (bytes32 id) {
        IntakeAccount account = buyer.accountOf(user);
        vm.startPrank(user);
        imd.transfer(address(account), PRICE);
        account.execute(IMD, 0, abi.encodeCall(IERC20.approve, (INTAKE, PRICE)));
        bytes memory data = abi.encodeCall(
            IIntake.requestWithFailure, (JOB_CONTINUE, body, IIntake.Callback(user, bytes4(0)), bytes4(0), IMD, PRICE)
        );
        id = abi.decode(account.execute(INTAKE, 0, data), (bytes32));
        vm.stopPrank();
    }
}
