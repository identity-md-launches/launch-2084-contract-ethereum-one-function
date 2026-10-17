// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WebsiteBuyer} from "../src/WebsiteBuyer.sol";
import {IntakeAccount} from "../src/IntakeAccount.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

abstract contract WebsiteBuyerBase is Test {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant OWNER = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    bytes32 internal constant JOB_OPEN = bytes32("job.open@job-1");
    bytes32 internal constant JOB_CONTINUE = bytes32("job.continue@job-1");
    uint256 internal constant PRICE = 0.5 ether;
    string internal constant URI = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/result.json";

    WebsiteBuyer internal buyer;
    MockIMD internal imd;
    MockPoolManager internal manager;
    MockIntake internal intake;
    address internal alice;
    address internal bob;
    address internal writer;
    address internal treasury;

    function setUp() public virtual {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        writer = makeAddr("writer");
        treasury = makeAddr("treasury");
        vm.chainId(1);
        deployCodeTo("MockIMD.sol:MockIMD", IMD);
        deployCodeTo("MockPoolManager.sol:MockPoolManager", MANAGER);
        deployCodeTo("MockIntake.sol:MockIntake", INTAKE);
        imd = MockIMD(IMD);
        manager = MockPoolManager(MANAGER);
        intake = MockIntake(INTAKE);
        manager.configure(2 ether, 10_000);
        intake.configure(treasury, writer, JOB_OPEN, IMD, PRICE);
        intake.setPrice(JOB_CONTINUE, IMD, PRICE);
        imd.mint(MANAGER, 1_000_000 ether);
        buyer = new WebsiteBuyer(OWNER);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _buy(address user) internal returns (bytes32) {
        vm.prank(user);
        return buyer.buyWebsite{value: 1 ether}("a bakery in Lisbon");
    }

    function _assertClean(address user) internal view {
        assertEq(address(buyer).balance, 0, "hub ETH");
        assertEq(imd.balanceOf(address(buyer)), 0, "hub IMD");
        IntakeAccount account = buyer.accountOf(user);
        assertEq(address(account).balance, 0, "account ETH");
        assertEq(imd.balanceOf(address(account)), 0, "account IMD");
        assertEq(imd.allowance(address(account), address(intake)), 0, "account approval");
        assertEq(imd.allowance(address(buyer), address(intake)), 0, "hub approval");
        assertEq(imd.balanceOf(address(intake)), 0, "intake must forward price");
        assertEq(manager.debt(), 0, "unsettled ETH");
        assertEq(manager.credit(), 0, "unsettled IMD");
    }

    function _repeat(uint256 length, bytes1 char) internal pure returns (string memory) {
        bytes memory data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = char;
        }
        return string(data);
    }
}
