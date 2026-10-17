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
    /// @dev Default action id; the owner can move purchases to a newer version with setAction.
    bytes32 public constant JOB_OPEN = bytes32("job.open@job-1");
    uint256 public constant MAX_WORDS_BYTES = 1000;
    /// @dev Longer result URIs are emitted but not stored, so the 200 000 gas callback always fits.
    uint256 public constant MAX_STORED_URI_BYTES = 128;

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
    error InvalidAction();
    error Expired(uint256 deadline);
    error SurplusTooLow(uint256 surplus, uint256 minSurplus);

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
    event ActionChanged(bytes32 indexed previousAction, bytes32 indexed nextAction);

    IIntake public intake;
    bytes32 public action;
    mapping(address buyer => IntakeAccount account) public accountOf;
    mapping(bytes32 requestId => Request request) private _requests;

    // Nonzero only between our unlock call and its one authenticated callback.
    uint256 private _swapAmount;

    /// @param owner_ Launch owner, supplied explicitly even when a factory deploys this contract.
    /// @dev Does not call dependencies or require code: deployable on an empty chain.
    constructor(address owner_) Ownable(owner_) {
        intake = IIntake(INITIAL_INTAKE);
        emit IntakeChanged(address(0), INITIAL_INTAKE);
        action = JOB_OPEN;
        emit ActionChanged(bytes32(0), JOB_OPEN);
    }

    /// @notice Buy one hosted website. All value is spent swapping ETH; surplus is returned in IMD.
    /// The only floor is the live price: use buyWebsiteWithMinimum to bound the surplus and time.
    /// @return requestId Intake request identifier used by events, requestOf and callbacks.
    function buyWebsite(string calldata words) external payable nonReentrant whenNotPaused returns (bytes32 requestId) {
        return _buy(words, 0);
    }

    /// @notice Same purchase, reverting unless at least minSurplus IMD comes back to the buyer and
    /// the transaction is mined no later than deadline. Protects against sandwiches, stale
    /// transactions and a price raised between quote and inclusion.
    /// @param words The buyer's description of the website.
    /// @param minSurplus Minimum IMD returned to the buyer after the live price is paid.
    /// @param deadline Latest block timestamp at which the purchase may execute.
    /// @return requestId Intake request identifier used by events, requestOf and callbacks.
    function buyWebsiteWithMinimum(string calldata words, uint256 minSurplus, uint256 deadline)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (bytes32 requestId)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        return _buy(words, minSurplus);
    }

    function _buy(string calldata words, uint256 minSurplus) private returns (bytes32 requestId) {
        bytes memory body = bodyOf(words);
        if (msg.value == 0 || msg.value > uint256(uint128(type(int128).max))) revert InvalidETHAmount();

        IIntake to = intake;
        uint256 price = to.priceOf(action, IMD);
        if (price == 0) revert ActionNotSold();

        uint256 beforeSwap = IERC20(IMD).balanceOf(address(this));
        _swapAmount = msg.value;
        uint256 received = abi.decode(IPoolManager(POOL_MANAGER).unlock(""), (uint256));
        if (_swapAmount != 0) revert UnexpectedUnlock();
        if (IERC20(IMD).balanceOf(address(this)) != beforeSwap + received) revert UnexpectedTokenBalance();
        if (received < price) revert InsufficientIMD(received, price);
        uint256 surplus = received - price;
        if (surplus < minSurplus) revert SurplusTooLow(surplus, minSurplus);

        IntakeAccount account = _accountFor(msg.sender);
        requestId = _ask(account, to, body, price);

        if (surplus != 0) IERC20(IMD).safeTransfer(msg.sender, surplus);
        if (IERC20(IMD).balanceOf(address(this)) != beforeSwap) revert UnexpectedTokenBalance();
        emit WebsiteRequested(requestId, msg.sender, address(to), address(account), msg.value, received, price, surplus);
    }

    function _accountFor(address buyer) private returns (IntakeAccount account) {
        account = accountOf[buyer];
        if (address(account) == address(0)) {
            account = new IntakeAccount{salt: bytes32(uint256(uint160(buyer)))}(buyer);
            accountOf[buyer] = account;
            emit AccountOpened(buyer, address(account));
        }
    }

    function _ask(IntakeAccount account, IIntake to, bytes memory body, uint256 price)
        private
        returns (bytes32 requestId)
    {
        IERC20(IMD).safeTransfer(address(account), price);
        requestId = account.ask(
            to,
            action,
            body,
            IIntake.Callback(address(this), this.onIntakeResult.selector),
            this.onIntakeFailure.selector,
            IMD,
            price
        );
        if (_requests[requestId].state != State.None) revert DuplicateRequest(requestId);
        _requests[requestId] = Request(msg.sender, State.Pending, 0, address(to), price, bytes32(0), bytes32(0), "");
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
    /// @dev Words must be well-formed UTF-8 (no overlong forms, surrogates or code points past
    /// U+10FFFF) with no double quote, backslash or ASCII control byte, so the body is strict JSON.
    function bodyOf(string calldata words) public pure returns (bytes memory) {
        uint256 n = bytes(words).length;
        if (n == 0 || n > MAX_WORDS_BYTES) revert BadWords();
        uint256 i;
        while (i < n) {
            uint8 c = uint8(bytes(words)[i]);
            if (c < 0x80) {
                if (c < 0x20 || c == 0x7f || c == 0x22 || c == 0x5c) revert BadWords();
                ++i;
                continue;
            }
            (uint256 extra, uint8 lo, uint8 hi) = _utf8Lead(c);
            if (n - i <= extra) revert BadWords();
            c = uint8(bytes(words)[i + 1]);
            if (c < lo || c > hi) revert BadWords();
            for (uint256 k = 2; k <= extra; ++k) {
                c = uint8(bytes(words)[i + k]);
                if (c < 0x80 || c > 0xbf) revert BadWords();
            }
            i += extra + 1;
        }
        return
            abi.encodePacked(
                '{"objective":"Build a one-page website: ', words, '","skill":"build-website","host":true}'
            );
    }

    /// @dev Continuation count and allowed range of the byte after a UTF-8 lead byte (RFC 3629).
    function _utf8Lead(uint8 c) private pure returns (uint256 extra, uint8 lo, uint8 hi) {
        lo = 0x80;
        hi = 0xbf;
        if (c >= 0xc2 && c <= 0xdf) {
            extra = 1;
        } else if (c == 0xe0) {
            extra = 2;
            lo = 0xa0;
        } else if (c == 0xed) {
            extra = 2;
            hi = 0x9f;
        } else if (c >= 0xe1 && c <= 0xef) {
            extra = 2;
        } else if (c == 0xf0) {
            extra = 3;
            lo = 0x90;
        } else if (c >= 0xf1 && c <= 0xf3) {
            extra = 3;
        } else if (c == 0xf4) {
            extra = 3;
            hi = 0x8f;
        } else {
            revert BadWords();
        }
    }

    function poolKey() public pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), POOL_FEE, TICK_SPACING, IHooks(address(0)));
    }

    function requestOf(bytes32 requestId) external view returns (Request memory) {
        return _requests[requestId];
    }

    /// @notice Records the Intake writer's result; the hash is not an independent attestation.
    /// @dev The URI is always emitted; it is stored only up to MAX_STORED_URI_BYTES so that the
    /// Done state and the hash never depend on the URI's length under the callback's gas stipend.
    function onIntakeResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external {
        Request storage request = _pending(requestId);
        request.state = State.Done;
        request.resultHash = resultHash;
        if (bytes(uri).length <= MAX_STORED_URI_BYTES) request.uri = uri;
        emit WebsiteResult(requestId, request.buyer, resultHash, uri);
    }

    /// @notice Records a refusal (1), an end without result (2) or any later nonzero status the
    /// plane defines. The price has already been spent.
    /// @dev Panel metadata/signatures have no authority in this unsigned website-result protocol.
    function onIntakeFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata) external {
        Request storage request = _pending(requestId);
        if (status == 0) revert InvalidFailureStatus(status);
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

    /// @notice Points future purchases at another Intake action id, for example a newer job.open
    /// version priced at the same Intake. Pending requests are unaffected.
    function setAction(bytes32 next) external onlyOwner nonReentrant {
        if (next == bytes32(0)) revert InvalidAction();
        bytes32 previous = action;
        action = next;
        emit ActionChanged(previous, next);
    }

    /// @notice Pauses or resumes new purchases. Payer accounts and callbacks remain available.
    function setPaused(bool value) external onlyOwner nonReentrant {
        if (value) _pause();
        else _unpause();
    }
}
