// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";

/// @dev Intake v2 payment and delivery model. Off-chain project admission is simulated explicitly.
contract MockIntake is IIntake {
    using SafeERC20 for IERC20;

    struct StoredRequest {
        address payer;
        bytes32 action;
        bytes body;
        Callback callback;
        bytes4 onFailure;
        address asset;
        uint256 amount;
        bool completed;
        bool delivered;
    }

    error ActionNotSold();
    error ShortPayment();
    error EmptyBody();
    error NotWriter();
    error RequestRejected();

    event Requested(
        bytes32 indexed requestId, address indexed payer, bytes32 indexed action, bytes body, uint256 amount
    );
    event Completed(bytes32 indexed requestId, uint8 status, bool delivered);

    address public treasury;
    address public writer;
    uint256 public nonce;
    bool public rejectRequest;
    bool public omitPayment;
    bool public fixedIdEnabled;
    bytes32 public fixedId;
    address public reentryTarget;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    mapping(bytes32 => mapping(address => uint256)) private _prices;
    mapping(bytes32 => StoredRequest) private _requests;
    mapping(bytes32 => address) public projectPayer;

    function configure(address treasury_, address writer_, bytes32 action, address asset, uint256 price) external {
        treasury = treasury_;
        writer = writer_;
        _prices[action][asset] = price;
    }

    function setPrice(bytes32 action, address asset, uint256 price) external {
        _prices[action][asset] = price;
    }

    function configureFaults(bool reject_, bool omit_) external {
        rejectRequest = reject_;
        omitPayment = omit_;
    }

    function setFixedId(bytes32 value) external {
        fixedIdEnabled = true;
        fixedId = value;
    }

    function setReentry(address target) external {
        reentryTarget = target;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256) {
        return _prices[action][asset];
    }

    function requestOf(bytes32 id) external view returns (StoredRequest memory) {
        return _requests[id];
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        if (rejectRequest) revert RequestRejected();
        uint256 price = _prices[action][asset];
        if (price == 0) revert ActionNotSold();
        if (amount < price) revert ShortPayment();
        if (body.length == 0) revert EmptyBody();
        require(msg.value == 0, "IMD payments only");
        if (!omitPayment) IERC20(asset).safeTransferFrom(msg.sender, treasury, amount);
        id = fixedIdEnabled ? fixedId : keccak256(abi.encode(address(this), ++nonce, msg.sender, action, body));
        _requests[id] = StoredRequest(msg.sender, action, body, callback, onFailure, asset, amount, false, false);
        if (reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call{value: 1}(abi.encodeWithSignature("buyWebsite(string)", "reentry"));
        }
        emit Requested(id, msg.sender, action, body, amount);
    }

    function complete(bytes32 id, uint8 status, bytes calldata args) external returns (bool delivered) {
        if (msg.sender != writer) revert NotWriter();
        StoredRequest storage request = _requests[id];
        require(request.payer != address(0) && !request.completed, "not pending");
        request.completed = true;
        bytes4 selector = status == 0 ? request.callback.selector : request.onFailure;
        (delivered,) = request.callback.target.call{gas: 200_000}(bytes.concat(selector, args));
        request.delivered = delivered;
        emit Completed(id, status, delivered);
    }

    function registerProject(bytes32 project, bytes32 openingRequest) external {
        if (msg.sender != writer) revert NotWriter();
        projectPayer[project] = _requests[openingRequest].payer;
    }

    /// @dev The plane performs this check off chain, spending a refusal's price as well.
    function admitContinuation(bytes32 id, bytes32 project) external returns (bool accepted) {
        if (msg.sender != writer) revert NotWriter();
        StoredRequest storage request = _requests[id];
        require(request.action == bytes32("job.continue@job-1"), "not continuation");
        accepted = projectPayer[project] != address(0) && projectPayer[project] == request.payer;
        request.completed = true;
    }
}
