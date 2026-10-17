// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WebsiteBuyerBase, WebsiteBuyer} from "./WebsiteBuyerBase.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract WebsiteRevisionTest is WebsiteBuyerBase {
    event ActionChanged(bytes32 indexed previousAction, bytes32 indexed nextAction);

    bytes32 internal constant JOB_OPEN_2 = bytes32("job.open@job-2");

    // The base mock pool returns 2 IMD for any swap, so 1 ETH leaves 1.5 IMD above the price.
    uint256 internal constant SURPLUS = 1.5 ether;

    function test_minimumSurplusMetIsAccepted() public {
        vm.prank(alice);
        bytes32 id = buyer.buyWebsiteWithMinimum{value: 1 ether}("a bakery", SURPLUS, block.timestamp);
        assertEq(imd.balanceOf(alice), SURPLUS);
        assertEq(imd.balanceOf(treasury), PRICE);
        assertEq(intake.requestOf(id).body, buyer.bodyOf("a bakery"));
        _assertClean(alice);
    }

    function test_surplusBelowMinimumRevertsBeforeAnyPayment() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.SurplusTooLow.selector, SURPLUS, SURPLUS + 1));
        buyer.buyWebsiteWithMinimum{value: 1 ether}("a bakery", SURPLUS + 1, block.timestamp);
        assertEq(alice.balance, 100 ether);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(intake.nonce(), 0);
        assertEq(address(buyer.accountOf(alice)), address(0));
    }

    function test_priceRaisedAfterQuoteIsCaughtByMinimum() public {
        intake.setPrice(JOB_OPEN, IMD, 1.9 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.SurplusTooLow.selector, 0.1 ether, SURPLUS));
        buyer.buyWebsiteWithMinimum{value: 1 ether}("a bakery", SURPLUS, block.timestamp);
        assertEq(imd.balanceOf(treasury), 0);
    }

    function test_expiredDeadlineReverts() public {
        vm.warp(1_000_000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WebsiteBuyer.Expired.selector, uint256(999_999)));
        buyer.buyWebsiteWithMinimum{value: 1 ether}("a bakery", 0, 999_999);
        assertEq(alice.balance, 100 ether);
        assertEq(intake.nonce(), 0);
    }

    function test_minimumVariantRespectsPauseAndBadWords() public {
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.BadWords.selector);
        buyer.buyWebsiteWithMinimum{value: 1 ether}('x"y', 0, block.timestamp);
        vm.prank(OWNER);
        buyer.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        buyer.buyWebsiteWithMinimum{value: 1 ether}("a bakery", 0, block.timestamp);
    }

    function test_ownerMovesPurchasesToNewActionVersionKeepingAccounts() public {
        bytes32 first = _buy(alice);
        intake.setPrice(JOB_OPEN, IMD, 0);
        intake.setPrice(JOB_OPEN_2, IMD, PRICE);
        vm.prank(alice);
        vm.expectRevert(WebsiteBuyer.ActionNotSold.selector);
        buyer.buyWebsite{value: 1 ether}("a bakery");

        vm.expectEmit(true, true, false, true, address(buyer));
        emit ActionChanged(JOB_OPEN, JOB_OPEN_2);
        vm.prank(OWNER);
        buyer.setAction(JOB_OPEN_2);
        assertEq(buyer.action(), JOB_OPEN_2);

        bytes32 second = _buy(alice);
        assertEq(intake.requestOf(second).action, JOB_OPEN_2);
        assertEq(intake.requestOf(second).payer, intake.requestOf(first).payer);
        _assertClean(alice);
    }

    function test_setActionOnlyOwnerAndNonZero() public {
        assertEq(buyer.action(), JOB_OPEN);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        buyer.setAction(JOB_OPEN_2);
        vm.prank(OWNER);
        vm.expectRevert(WebsiteBuyer.InvalidAction.selector);
        buyer.setAction(bytes32(0));
        assertEq(buyer.action(), JOB_OPEN);
    }

    function test_malformedUTF8IsRefusedBeforeAnySwap() public {
        bytes[] memory bad = new bytes[](16);
        bad[0] = hex"ff";
        bad[1] = hex"fe";
        bad[2] = hex"c080"; // overlong NUL
        bad[3] = hex"c1bf"; // overlong
        bad[4] = hex"80"; // lone continuation
        bad[5] = hex"61bf62";
        bad[6] = hex"e08080"; // overlong three-byte
        bad[7] = hex"eda080"; // UTF-16 surrogate
        bad[8] = hex"f4908080"; // above U+10FFFF
        bad[9] = hex"f5808080";
        bad[10] = hex"f08f8080"; // overlong four-byte
        bad[11] = hex"c3"; // truncated
        bad[12] = hex"e282"; // truncated
        bad[13] = hex"f09f98"; // truncated
        bad[14] = hex"c341"; // ASCII where a continuation is due
        bad[15] = hex"e2822c"; // truncated three-byte before ASCII
        for (uint256 i; i < bad.length; ++i) {
            string memory text = string(bytes.concat("site ", bad[i], " end"));
            vm.expectRevert(WebsiteBuyer.BadWords.selector);
            buyer.bodyOf(text);
            vm.prank(alice);
            vm.expectRevert(WebsiteBuyer.BadWords.selector);
            buyer.buyWebsite{value: 1 ether}(text);
            // Also at the very end of the words, where a truncated sequence has no following byte.
            vm.expectRevert(WebsiteBuyer.BadWords.selector);
            buyer.bodyOf(string(bytes.concat("site ", bad[i])));
        }
        assertEq(manager.swaps(), 0);
        assertEq(intake.nonce(), 0);
    }

    function test_wellFormedUTF8BoundariesAreAccepted() public view {
        bytes[] memory good = new bytes[](8);
        good[0] = hex"c280"; // U+0080
        good[1] = hex"dfbf"; // U+07FF
        good[2] = hex"e0a080"; // U+0800
        good[3] = hex"ed9fbf"; // U+D7FF
        good[4] = hex"ee8080"; // U+E000
        good[5] = hex"efbfbf"; // U+FFFF
        good[6] = hex"f0908080"; // U+10000
        good[7] = hex"f48fbfbf"; // U+10FFFF
        for (uint256 i; i < good.length; ++i) {
            bytes memory words = bytes.concat(good[i], "x", good[i]);
            assertEq(
                buyer.bodyOf(string(words)),
                bytes.concat(
                    '{"objective":"Build a one-page website: ', words, '","skill":"build-website","host":true}'
                )
            );
        }
    }

    function testFuzz_everyScalarValueIsAccepted(uint32 raw) public view {
        uint256 cp = bound(raw, 0x80, 0x10ffff);
        if (cp >= 0xd800 && cp <= 0xdfff) cp += 0x800;
        buyer.bodyOf(string(_encode(cp)));
    }

    function _encode(uint256 cp) private pure returns (bytes memory) {
        if (cp < 0x800) return abi.encodePacked(bytes1(uint8(0xc0 | (cp >> 6))), bytes1(uint8(0x80 | (cp & 0x3f))));
        if (cp < 0x10000) {
            return abi.encodePacked(
                bytes1(uint8(0xe0 | (cp >> 12))),
                bytes1(uint8(0x80 | ((cp >> 6) & 0x3f))),
                bytes1(uint8(0x80 | (cp & 0x3f)))
            );
        }
        return abi.encodePacked(
            bytes1(uint8(0xf0 | (cp >> 18))),
            bytes1(uint8(0x80 | ((cp >> 12) & 0x3f))),
            bytes1(uint8(0x80 | ((cp >> 6) & 0x3f))),
            bytes1(uint8(0x80 | (cp & 0x3f)))
        );
    }
}
