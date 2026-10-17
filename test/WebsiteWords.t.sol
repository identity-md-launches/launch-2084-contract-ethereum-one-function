// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WebsiteBuyerBase, WebsiteBuyer} from "./WebsiteBuyerBase.t.sol";

contract WebsiteWordsTest is WebsiteBuyerBase {
    function test_rejectsEmptyQuoteBackslashNewlineAndExcessBytes() public {
        string[5] memory bad = ["", 'site", "owner":"attacker', "back\\slash", "new\nline", _repeat(1001, "a")];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(WebsiteBuyer.BadWords.selector);
            buyer.buyWebsite{value: 1 ether}(bad[i]);
        }
        assertEq(manager.swaps(), 0);
        assertEq(alice.balance, 100 ether);
    }

    function test_everyASCIIControlByteIncludingDELIsRefused() public {
        for (uint256 c; c <= 0x20; ++c) {
            bytes1 forbidden = c == 0x20 ? bytes1(0x7f) : bytes1(uint8(c));
            string memory text = string(abi.encodePacked("hello", forbidden, "world"));
            vm.expectRevert(WebsiteBuyer.BadWords.selector);
            buyer.bodyOf(text);
            vm.prank(alice);
            vm.expectRevert(WebsiteBuyer.BadWords.selector);
            buyer.buyWebsite{value: 1 ether}(text);
        }
        assertEq(intake.nonce(), 0);
    }

    function test_oneByteAndExactly1000BytesAreAccepted() public {
        vm.startPrank(alice);
        buyer.buyWebsite{value: 1 ether}("x");
        bytes32 id = buyer.buyWebsite{value: 1 ether}(_repeat(1000, "x"));
        vm.stopPrank();
        assertEq(intake.requestOf(id).body, buyer.bodyOf(_repeat(1000, "x")));
        _assertClean(alice);
    }

    function test_UTF8AllowedAndLimitCountsBytes() public {
        string memory unicodeWords = unicode"Café menu, prices in € — 東京";
        vm.prank(alice);
        bytes32 id = buyer.buyWebsite{value: 1 ether}(unicodeWords);
        assertEq(
            intake.requestOf(id).body,
            abi.encodePacked(
                '{"objective":"Build a one-page website: ', unicodeWords, '","skill":"build-website","host":true}'
            )
        );
        bytes memory multiByte = new bytes(1000);
        for (uint256 i; i < 1000; i += 2) {
            multiByte[i] = 0xc3;
            multiByte[i + 1] = 0xa9;
        }
        buyer.bodyOf(string(multiByte));
        vm.expectRevert(WebsiteBuyer.BadWords.selector);
        buyer.bodyOf(string(bytes.concat(multiByte, hex"c3a9")));
    }

    function testFuzz_validWordsCannotInjectJSON(bytes memory data) public view {
        uint256 length = data.length % 1000 + 1;
        bytes memory words = new bytes(length);
        for (uint256 i; i < length; ++i) {
            // Restrict fuzzed bytes to harmless printable letters, punctuation, spaces and digits.
            uint8 c = data.length == 0 ? 0x61 : uint8(data[i % data.length]) % 95 + 0x20;
            if (c == 0x22 || c == 0x5c) c = 0x61;
            words[i] = bytes1(c);
        }
        assertEq(
            buyer.bodyOf(string(words)),
            bytes.concat('{"objective":"Build a one-page website: ', words, '","skill":"build-website","host":true}')
        );
    }

    function testFuzz_invalidByteAtAnyPositionIsRefused(uint16 size, uint16 position, uint8 badIndex) public {
        uint256 length = bound(size, 1, 1000);
        bytes memory words = bytes(_repeat(length, "a"));
        uint8 choice = badIndex % 35;
        bytes1 bad =
            choice < 32 ? bytes1(choice) : choice == 32 ? bytes1(0x22) : choice == 33 ? bytes1(0x5c) : bytes1(0x7f);
        words[position % length] = bad;
        vm.expectRevert(WebsiteBuyer.BadWords.selector);
        buyer.bodyOf(string(words));
    }
}
