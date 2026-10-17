// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WebsiteBuyer} from "../src/WebsiteBuyer.sol";
import {IntakeAccount} from "../src/IntakeAccount.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DeploymentFactory {
    function deploy(address owner, bytes32 salt) external returns (WebsiteBuyer) {
        return new WebsiteBuyer{salt: salt}(owner);
    }
}

contract DeploymentTest is Test {
    address private constant OWNER = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;

    function test_factoryConstructorWorksWithNoExternalContractsAndExplicitOwner() public {
        DeploymentFactory factory = new DeploymentFactory();
        WebsiteBuyer buyer = factory.deploy(OWNER, keccak256("website buyer deployment"));
        assertEq(buyer.IMD().code.length, 0);
        assertEq(buyer.POOL_MANAGER().code.length, 0);
        assertEq(address(buyer.intake()).code.length, 0);
        assertEq(buyer.owner(), OWNER);
        assertNotEq(buyer.owner(), address(factory));
        assertNotEq(buyer.owner(), address(this));
        assertLt(type(WebsiteBuyer).creationCode.length + 32, 49_152);
        _checkRuntime(address(buyer));
        IntakeAccount account = new IntakeAccount(OWNER);
        _checkRuntime(address(account));
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new WebsiteBuyer(address(0));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
