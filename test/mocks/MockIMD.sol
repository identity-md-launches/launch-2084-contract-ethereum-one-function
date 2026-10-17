// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test token with independently configurable failure and reentrancy paths.
contract MockIMD is ERC20 {
    address public failRecipient;
    bool public failApproval;
    bool public emptyReturn;
    uint256 public transferFee;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryError;

    constructor() ERC20("Mock IMD", "IMD") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function configure(address failRecipient_, bool failApproval_, bool emptyReturn_, uint256 transferFee_) external {
        failRecipient = failRecipient_;
        failApproval = failApproval_;
        emptyReturn = emptyReturn_;
        transferFee = transferFee_;
    }

    function configureReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (failApproval) return false;
        super.approve(spender, amount);
        if (emptyReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == failRecipient) return false;
        super.transfer(to, amount);
        if (transferFee != 0) _burn(to, transferFee);
        if (reentryTarget != address(0) && !reentryAttempted) {
            reentryAttempted = true;
            (reentrySucceeded, reentryError) = reentryTarget.call{value: 1}(reentryData);
        }
        if (emptyReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (to == failRecipient) return false;
        super.transferFrom(from, to, amount);
        if (emptyReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}
