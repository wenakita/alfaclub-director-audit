// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IOfficialUERC20Factory} from "./IOfficialUERC20Factory.sol";
import {UERC20Metadata} from "./UERC20Metadata.sol";
import {LaunchConfig, IRegistryRecipients} from "../roomtoken/RoomTokenFactory.sol";
import {RoomFeeSplitter, SplitterParams} from "../roomtoken/RoomFeeSplitter.sol";
import {INonfungiblePositionManager} from "../roomtoken/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouterMinimal} from "../roomtoken/interfaces/ISwapRouterMinimal.sol";
import {IUniswapV3PoolMinimal} from "../roomtoken/interfaces/IUniswapV3PoolMinimal.sol";
import {TickMath} from "../roomtoken/libraries/TickMath.sol";

/// Two-phase official UERC20 + Uniswap V3 launch.
///
/// `launch` mints through Uniswap's official factory (logo ingest) and
/// reserves the V3 USDG pool at the config tick with zero liquidity. This
/// contract holds the 1B supply until the creator calls `open` after
/// `tradingOpensAt`, which locks LP in `RoomFeeSplitter` and optionally
/// runs one bounded dev buy.
///
/// Official UERC20 transfers freely from block 0 (no `_update` caps). Timed
/// open is enforced here, not on the token. `image` must be a non-empty
/// `https://` URL with a host.
///
/// Seeding the empty pool in the same `launch` transaction closes the
/// cheap grief where someone pre-inits the predicted pool at the wrong
/// price. Price cannot move afterward while this contract still holds the
/// full supply (no liquidity, no tokens for an attacker to add).
///
/// If `open` never runs, `recoverUnopened` burns the held official
/// inventory (it is never sent to the creator) and returns only the unused
/// dev-buy quote. The launch fee is not refunded. The room stays consumed.
struct AlfaClubLaunchParams {
    uint256 roomId;
    uint32 configId;
    string name;
    string symbol;
    string description;
    string website;
    string image;
    address roomFundRecipient;
    uint64 tradingOpensAt;
    uint64 deadline;
    bytes32 graffiti;
    uint256 devBuyQuoteIn;
    uint256 devBuyMinOut;
    bytes authoritySignature;
    bool usePermit;
    uint256 permitValue;
    uint256 permitDeadline;
    uint8 permitV;
    bytes32 permitR;
    bytes32 permitS;
}

struct PendingLaunch {
    address token;
    address creator;
    uint32 configId;
    uint64 tradingOpensAt;
    uint256 devBuyQuoteIn;
    uint256 devBuyMinOut;
    bool opened;
    bool recovered;
    address pool;
}

contract AlfaClubDirector is Ownable, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 private constant LAUNCH_TYPEHASH = keccak256(
        "AlfaClubLaunch(uint256 roomId,address creator,address roomFundRecipient,bytes32 economicsHash,uint64 tradingOpensAt,uint64 deadline,bytes32 graffiti)"
    );
    uint24 public constant POOL_FEE = 10000;
    int24 public constant TICK_LOWER = -887200;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant Q96 = 2 ** 96;

    IOfficialUERC20Factory public immutable officialFactory;
    IERC20 public immutable quote;
    INonfungiblePositionManager public immutable npm;
    ISwapRouterMinimal public immutable swapRouter;
    address public immutable v3Factory;
    IRegistryRecipients public immutable registry;

    address public authority;
    address public defaultOperator;
    LaunchConfig[] private _configs;
    mapping(uint256 roomId => PendingLaunch) public pendingOf;
    mapping(uint256 roomId => address token) public tokenOf;

    error UnknownConfig();
    error RoomAlreadyLaunched();
    error CountdownOutOfBounds();
    error AuthorizationExpired();
    error BadAuthoritySignature();
    error TokenOrderingBroken();
    error PermitValueMismatch();
    error PoolPriceMismatch();
    error DevBuyExceedsCap();
    error DependencyMismatch();
    error UnknownLaunch();
    error AlreadyOpened();
    error AlreadyRecovered();
    error TradingNotOpen();
    error EmptyImage();
    error BadImage();
    error NotCreator();
    error NotAuthorized();
    error ZeroRecipient();
    error ZeroDependency();
    error MintSupplyMismatch();
    error EmptyInventory();

    event AlfaClubTokenLaunched(
        uint256 indexed roomId, address token, address creator, uint32 configId, uint64 tradingOpensAt
    );
    event AlfaClubLiquiditySeeded(uint256 indexed roomId, address token, address pool, address splitter);
    event AlfaClubTokenRecovered(
        uint256 indexed roomId, address token, address recipient, uint256 tokenAmount, uint256 quoteAmount
    );
    event ConfigAppended(uint32 indexed configId);
    event AuthoritySet(address authority);
    event DefaultOperatorSet(address operator);

    constructor(
        address owner_,
        address authority_,
        address defaultOperator_,
        address officialFactory_,
        address quote_,
        address npm_,
        address swapRouter_,
        address v3Factory_,
        address registry_
    ) Ownable(owner_) EIP712("AlfaClubDirector", "1") {
        if (
            officialFactory_ == address(0) || quote_ == address(0) || npm_ == address(0) || swapRouter_ == address(0)
                || v3Factory_ == address(0) || registry_ == address(0)
        ) revert ZeroDependency();
        if (
            INonfungiblePositionManager(npm_).factory() != v3Factory_
                || ISwapRouterMinimal(swapRouter_).factory() != v3Factory_
        ) revert DependencyMismatch();

        authority = authority_;
        defaultOperator = defaultOperator_;
        officialFactory = IOfficialUERC20Factory(officialFactory_);
        quote = IERC20(quote_);
        npm = INonfungiblePositionManager(npm_);
        swapRouter = ISwapRouterMinimal(swapRouter_);
        v3Factory = v3Factory_;
        registry = IRegistryRecipients(registry_);
    }

    function appendConfig(LaunchConfig calldata c) external onlyOwner returns (uint32 configId) {
        require(c.creatorBps + c.roomFundBps + c.platformBps == 10_000, "bps");
        _configs.push(c);
        configId = uint32(_configs.length - 1);
        emit ConfigAppended(configId);
    }

    function configCount() external view returns (uint32) {
        return uint32(_configs.length);
    }

    function configAt(uint32 id) external view returns (LaunchConfig memory) {
        if (id >= _configs.length) revert UnknownConfig();
        return _configs[id];
    }

    function setAuthority(address next) external onlyOwner {
        authority = next;
        emit AuthoritySet(next);
    }

    function setDefaultOperator(address next) external onlyOwner {
        defaultOperator = next;
        emit DefaultOperatorSet(next);
    }

    function predictToken(string calldata name, string calldata symbol, bytes32 graffiti)
        external
        view
        returns (address)
    {
        return officialFactory.getUERC20Address(name, symbol, 18, address(this), graffiti);
    }

    function economicsHash(
        uint32 configId,
        uint256 devBuyQuoteIn,
        uint256 devBuyMinOut,
        string calldata name,
        string calldata symbol,
        string calldata description,
        string calldata website,
        string calldata image
    ) public view returns (bytes32) {
        if (configId >= _configs.length) revert UnknownConfig();
        LaunchConfig memory c = _configs[configId];
        return keccak256(
            abi.encode(
                configId,
                c.launchFeeQuote,
                c.creatorBps,
                c.roomFundBps,
                c.platformBps,
                c.initTick,
                c.capWindowSecs,
                c.walletCapBps,
                c.devBuyCapBps,
                devBuyQuoteIn,
                devBuyMinOut,
                name,
                symbol,
                description,
                website,
                image
            )
        );
    }

    /// Phase 1: official factory mints 1B UERC20 to this contract and
    /// reserves the V3 pool at `initTick` with zero liquidity.
    function launch(AlfaClubLaunchParams calldata p) external returns (address tokenAddr) {
        LaunchConfig memory c = _configAt(p.configId);
        if (tokenOf[p.roomId] != address(0)) revert RoomAlreadyLaunched();
        if (block.timestamp > p.deadline) revert AuthorizationExpired();
        _requireHttpsImage(p.image);
        if (
            p.tradingOpensAt < block.timestamp + c.minCountdownSecs
                || p.tradingOpensAt > block.timestamp + c.maxCountdownSecs
        ) revert CountdownOutOfBounds();

        // Reject an unsustainable dev buy before taking funds or minting —
        // otherwise `open` would always revert DevBuyExceedsCap and the 1B
        // inventory would be stuck without recover.
        uint160 sqrtInit = TickMath.getSqrtRatioAtTick(c.initTick);
        _requireDevBuyWithinCap(p.devBuyQuoteIn, sqrtInit, c.devBuyCapBps, TOTAL_SUPPLY);

        _verifyAuthority(p);
        registry.ensureRoomFund(p.roomId, p.roomFundRecipient);
        _pullFunds(p, c);

        bytes memory data = abi.encode(
            UERC20Metadata({description: p.description, website: p.website, image: p.image, extraData: bytes("")})
        );
        tokenAddr = officialFactory.createToken(p.name, p.symbol, 18, TOTAL_SUPPLY, address(this), data, p.graffiti);
        if (tokenAddr <= address(quote)) revert TokenOrderingBroken();
        if (IERC20(tokenAddr).balanceOf(address(this)) != TOTAL_SUPPLY) revert MintSupplyMismatch();

        // Same transaction as the mint: no window for a wrong-price init.
        address poolAddr = _requirePoolAt(tokenAddr, sqrtInit);

        tokenOf[p.roomId] = tokenAddr;
        pendingOf[p.roomId] = PendingLaunch({
            token: tokenAddr,
            creator: msg.sender,
            configId: p.configId,
            tradingOpensAt: p.tradingOpensAt,
            devBuyQuoteIn: p.devBuyQuoteIn,
            devBuyMinOut: p.devBuyMinOut,
            opened: false,
            recovered: false,
            pool: poolAddr
        });

        (, address platformRecipient) = registry.recipientsOf(p.roomId);
        quote.safeTransfer(platformRecipient, c.launchFeeQuote);

        emit AlfaClubTokenLaunched(p.roomId, tokenAddr, msg.sender, p.configId, p.tradingOpensAt);
    }

    /// Phase 2: lock LP in the reserved pool, optional bounded dev buy.
    /// Creator-only. Rescue remains `recoverUnopened`.
    function open(uint256 roomId) external returns (address poolAddr, address splitterAddr) {
        PendingLaunch storage pending = pendingOf[roomId];
        if (pending.token == address(0)) revert UnknownLaunch();
        if (pending.recovered) revert AlreadyRecovered();
        if (pending.opened) revert AlreadyOpened();
        if (msg.sender != pending.creator) revert NotCreator();
        if (block.timestamp < pending.tradingOpensAt) revert TradingNotOpen();

        LaunchConfig memory c = _configAt(pending.configId);
        address tokenAddr = pending.token;
        uint256 held = IERC20(tokenAddr).balanceOf(address(this));
        if (held == 0) revert EmptyInventory();
        uint160 sqrtInit = TickMath.getSqrtRatioAtTick(c.initTick);
        _requireDevBuyWithinCap(pending.devBuyQuoteIn, sqrtInit, c.devBuyCapBps, held);

        // Reentrancy guard for the subsequent external calls. A reverting
        // `open` rolls this back, so the creator can still recover.
        pending.opened = true;

        poolAddr = _requirePoolAt(tokenAddr, sqrtInit);
        IUniswapV3PoolMinimal(poolAddr).increaseObservationCardinalityNext(c.cardinalityTarget);

        splitterAddr = address(
            new RoomFeeSplitter(
                SplitterParams({
                    npm: address(npm),
                    swapRouter: address(swapRouter),
                    pool: poolAddr,
                    token: tokenAddr,
                    quote: address(quote),
                    roomId: roomId,
                    registry: address(registry),
                    creatorRecipient: pending.creator,
                    operator: defaultOperator,
                    creatorBps: c.creatorBps,
                    roomFundBps: c.roomFundBps,
                    platformBps: c.platformBps,
                    twapWindowSecs: c.twapWindowSecs,
                    maxConversionDeviationBps: c.maxConversionDeviationBps,
                    maxConversionImpactBps: c.maxConversionImpactBps
                })
            )
        );

        IERC20(tokenAddr).forceApprove(address(npm), held);
        (uint256 positionId,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(quote),
                token1: tokenAddr,
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: c.initTick,
                amount0Desired: 0,
                amount1Desired: held,
                amount0Min: 0,
                amount1Min: 0,
                recipient: splitterAddr,
                deadline: block.timestamp
            })
        );
        RoomFeeSplitter(splitterAddr).registerPosition(positionId);

        if (pending.devBuyQuoteIn > 0) {
            quote.forceApprove(address(swapRouter), pending.devBuyQuoteIn);
            swapRouter.exactInputSingle(
                ISwapRouterMinimal.ExactInputSingleParams({
                    tokenIn: address(quote),
                    tokenOut: tokenAddr,
                    fee: POOL_FEE,
                    recipient: pending.creator,
                    deadline: block.timestamp,
                    amountIn: pending.devBuyQuoteIn,
                    amountOutMinimum: pending.devBuyMinOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        emit AlfaClubLiquiditySeeded(roomId, tokenAddr, poolAddr, splitterAddr);
    }

    /// Creator or owner rescue when `open` never runs. Burns the held
    /// official inventory (never paid to the creator) and returns only the
    /// unused dev-buy quote. Official UERC20 has no public burn, so inventory
    /// is sent to `BURN`. The launch fee is not refunded. The room stays
    /// consumed (`tokenOf` is not cleared).
    function recoverUnopened(uint256 roomId, address recipient) external {
        if (recipient == address(0)) revert ZeroRecipient();
        PendingLaunch storage pending = pendingOf[roomId];
        if (pending.token == address(0)) revert UnknownLaunch();
        if (pending.opened) revert AlreadyOpened();
        if (pending.recovered) revert AlreadyRecovered();
        if (msg.sender != owner() && msg.sender != pending.creator) revert NotAuthorized();

        pending.recovered = true;
        address tokenAddr = pending.token;
        uint256 quoteAmount = pending.devBuyQuoteIn;
        pending.devBuyQuoteIn = 0;

        uint256 tokenAmount = IERC20(tokenAddr).balanceOf(address(this));
        if (tokenAmount > 0) IERC20(tokenAddr).safeTransfer(BURN, tokenAmount);
        if (quoteAmount > 0) quote.safeTransfer(recipient, quoteAmount);

        emit AlfaClubTokenRecovered(roomId, tokenAddr, recipient, tokenAmount, quoteAmount);
    }

    function _configAt(uint32 id) internal view returns (LaunchConfig memory) {
        if (id >= _configs.length) revert UnknownConfig();
        return _configs[id];
    }

    function _requirePoolAt(address tokenAddr, uint160 sqrtInit) internal returns (address poolAddr) {
        poolAddr = npm.createAndInitializePoolIfNecessary(address(quote), tokenAddr, POOL_FEE, sqrtInit);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(poolAddr).slot0();
        if (sqrtPriceX96 != sqrtInit) revert PoolPriceMismatch();
    }

    function _requireHttpsImage(string calldata image) internal pure {
        bytes memory b = bytes(image);
        if (b.length == 0) revert EmptyImage();
        // `https://` plus at least one host byte. The contract cannot fetch
        // the picture; it only rejects empty / non-https strings.
        if (
            b.length < 9 || b[0] != "h" || b[1] != "t" || b[2] != "t" || b[3] != "p" || b[4] != "s" || b[5] != ":"
                || b[6] != "/" || b[7] != "/"
        ) revert BadImage();
    }

    function _requireDevBuyWithinCap(uint256 devBuyQuoteIn, uint160 sqrtInit, uint16 capBps, uint256 supply)
        internal
        pure
    {
        if (devBuyQuoteIn == 0) return;
        uint128 devBuyMaxOut = SafeCast.toUint128(Math.mulDiv(Math.mulDiv(devBuyQuoteIn, sqrtInit, Q96), sqrtInit, Q96));
        if (devBuyMaxOut > (supply * capBps) / 10_000) revert DevBuyExceedsCap();
    }

    function _verifyAuthority(AlfaClubLaunchParams calldata p) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                LAUNCH_TYPEHASH,
                p.roomId,
                msg.sender,
                p.roomFundRecipient,
                economicsHash(
                    p.configId, p.devBuyQuoteIn, p.devBuyMinOut, p.name, p.symbol, p.description, p.website, p.image
                ),
                p.tradingOpensAt,
                p.deadline,
                p.graffiti
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), p.authoritySignature);
        if (signer != authority || authority == address(0)) revert BadAuthoritySignature();
    }

    function _pullFunds(AlfaClubLaunchParams calldata p, LaunchConfig memory c) internal {
        uint256 total = uint256(c.launchFeeQuote) + p.devBuyQuoteIn;
        if (p.usePermit) {
            if (p.permitValue < total) revert PermitValueMismatch();
            try IERC20Permit(address(quote))
                .permit(msg.sender, address(this), p.permitValue, p.permitDeadline, p.permitV, p.permitR, p.permitS) {}
                catch {}
        }
        quote.safeTransferFrom(msg.sender, address(this), total);
    }
}
