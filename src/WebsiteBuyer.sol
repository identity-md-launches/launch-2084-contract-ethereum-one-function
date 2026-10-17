// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {IntakeAccount} from "./IntakeAccount.sol";

/// @title Buy a website with native ETH on Ethereum
/// @notice Swaps the entire payment for IMD, buys job.open at its live price through the buyer's
/// own payer account, and returns the surplus IMD. Results arrive asynchronously from the Intake.
/// @dev There is no exchange-rate promise: the minimum output is exactly the live Intake price.
contract WebsiteBuyer is Ownable2Step, Pausable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant INITIAL_INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    bytes32 public constant POOL_ID = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant TICK_SPACING = 200;
    bytes32 public constant JOB_OPEN = bytes32("job.open@job-1");
    uint256 public constant MAX_WORDS_BYTES = 1000;

    enum State {
        None,
        Pending,
        Done,
        Failed
    }

    struct Request {
        address buyer;
        State state;
        uint8 status;
        address intake;
        uint256 price;
        bytes32 resultHash;
        bytes32 reason;
        string uri;
    }

    error BadWords();
    error InvalidETHAmount();
    error ActionNotSold();
    error InvalidIntake();
    error UnexpectedUnlock();
    error IncompleteSwap();
    error InsufficientIMD(uint256 received, uint256 required);
    error UnexpectedTokenBalance();
    error DuplicateRequest(bytes32 requestId);
    error NotPending(bytes32 requestId);
    error InvalidFailureStatus(uint8 status);

    event AccountOpened(address indexed buyer, address indexed account);
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
    event WebsiteResult(bytes32 indexed requestId, address indexed buyer, bytes32 resultHash, string uri);
    event WebsiteFailure(bytes32 indexed requestId, address indexed buyer, uint8 status, bytes32 reason);
    event IntakeChanged(address indexed previousIntake, address indexed nextIntake);

    IIntake public intake;
    mapping(address buyer => IntakeAccount account) public accountOf;
    mapping(bytes32 requestId => Request request) private _requests;

    // Nonzero only between our unlock call and its one authenticated callback.
    uint256 private _swapAmount;

    /// @param owner_ Launch owner, supplied explicitly even when a factory deploys this contract.
    /// @dev Does not call dependencies or require code: deployable on an empty chain.
    constructor(address owner_) Ownable(owner_) {
        intake = IIntake(INITIAL_INTAKE);
        emit IntakeChanged(address(0), INITIAL_INTAKE);
    }

    /// @notice Buy one hosted website. All value is spent swapping ETH; surplus is returned in IMD.
    /// @return requestId Intake request identifier used by events, requestOf and callbacks.
    function buyWebsite(string calldata words) external payable nonReentrant whenNotPaused returns (bytes32 requestId) {
        bytes memory body = bodyOf(words);
        if (msg.value == 0 || msg.value > uint256(uint128(type(int128).max))) revert InvalidETHAmount();

        IIntake to = intake;
        uint256 price = to.priceOf(JOB_OPEN, IMD);
        if (price == 0) revert ActionNotSold();

        IERC20 token = IERC20(IMD);
        uint256 beforeSwap = token.balanceOf(address(this));
        _swapAmount = msg.value;
        uint256 received = abi.decode(IPoolManager(POOL_MANAGER).unlock(""), (uint256));
        if (_swapAmount != 0) revert UnexpectedUnlock();
        if (token.balanceOf(address(this)) != beforeSwap + received) revert UnexpectedTokenBalance();
        if (received < price) revert InsufficientIMD(received, price);

        IntakeAccount account = accountOf[msg.sender];
        if (address(account) == address(0)) {
            account = new IntakeAccount{salt: bytes32(uint256(uint160(msg.sender)))}(msg.sender);
            accountOf[msg.sender] = account;
            emit AccountOpened(msg.sender, address(account));
        }
        token.safeTransfer(address(account), price);
        requestId = account.ask(
            to,
            JOB_OPEN,
            body,
            IIntake.Callback(address(this), this.onIntakeResult.selector),
            this.onIntakeFailure.selector,
            IMD,
            price
        );
        if (_requests[requestId].state != State.None) revert DuplicateRequest(requestId);
        _requests[requestId] = Request(msg.sender, State.Pending, 0, address(to), price, bytes32(0), bytes32(0), "");

        uint256 surplus = received - price;
        if (surplus != 0) token.safeTransfer(msg.sender, surplus);
        if (token.balanceOf(address(this)) != beforeSwap) revert UnexpectedTokenBalance();
        emit WebsiteRequested(requestId, msg.sender, address(to), address(account), msg.value, received, price, surplus);
    }

    /// @dev PoolManager may call this exactly once during this contract's own purchase.
    /// Settles native debt and takes the complete IMD credit before releasing the manager lock.
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || _swapAmount == 0) revert UnexpectedUnlock();
        uint256 amount = _swapAmount;
        _swapAmount = 0;

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        PoolKey memory key = poolKey();
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        // v4 may partially fill at the price limit. This product promises an all-input swap.
        if (int256(delta.amount0()) != -int256(amount) || delta.amount1() <= 0) revert IncompleteSwap();
        uint256 received = uint256(uint128(delta.amount1()));
        // Reset any ERC20 sync left earlier in this transaction before settling native ETH.
        manager.sync(key.currency0);
        if (manager.settle{value: amount}() != amount) revert IncompleteSwap();
        manager.take(key.currency1, address(this), received);
        return abi.encode(received);
    }

    /// @notice Exact request body, available for previews before buying. No owner field is sent.
    function bodyOf(string calldata words) public pure returns (bytes memory) {
        bytes calldata text = bytes(words);
        if (text.length == 0 || text.length > MAX_WORDS_BYTES) revert BadWords();
        for (uint256 i; i < text.length; ++i) {
            bytes1 c = text[i];
            if (c < 0x20 || c == 0x7f || c == 0x22 || c == 0x5c) revert BadWords();
        }
        return
            abi.encodePacked(
                '{"objective":"Build a one-page website: ', words, '","skill":"build-website","host":true}'
            );
    }

    function poolKey() public pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), POOL_FEE, TICK_SPACING, IHooks(address(0)));
    }

    function requestOf(bytes32 requestId) external view returns (Request memory) {
        return _requests[requestId];
    }

    /// @notice Records the Intake writer's result; the hash is not an independent attestation.
    function onIntakeResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external {
        Request storage request = _pending(requestId);
        request.state = State.Done;
        request.resultHash = resultHash;
        request.uri = uri;
        emit WebsiteResult(requestId, request.buyer, resultHash, uri);
    }

    /// @notice Records refusal (1) or failure without result (2). The price has already been spent.
    /// @dev Panel metadata/signatures have no authority in this unsigned website-result protocol.
    function onIntakeFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata) external {
        Request storage request = _pending(requestId);
        if (status != 1 && status != 2) revert InvalidFailureStatus(status);
        request.state = State.Failed;
        request.status = status;
        request.reason = reason;
        emit WebsiteFailure(requestId, request.buyer, status, reason);
    }

    function _pending(bytes32 requestId) private view returns (Request storage request) {
        request = _requests[requestId];
        if (request.state != State.Pending || request.intake != msg.sender) revert NotPending(requestId);
    }

    /// @notice Changes only future purchases; pending callbacks retain their original Intake.
    function setIntake(IIntake next) external onlyOwner nonReentrant {
        if (address(next).code.length == 0 || address(next) == address(this) || address(next) == IMD) {
            revert InvalidIntake();
        }
        address previous = address(intake);
        intake = next;
        emit IntakeChanged(previous, address(next));
    }

    /// @notice Pauses or resumes new purchases. Payer accounts and callbacks remain available.
    function setPaused(bool value) external onlyOwner nonReentrant {
        if (value) _pause();
        else _unpause();
    }
}
