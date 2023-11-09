pragma solidity ^0.8.22;

uint256 constant MAX_ACTION_GAS = 32e6;

// - Everyone picks a player to be builder for their actions?
// - Public mempool for actions and highest bidder gets to build the block?
//      - Could be interesting because it might be worth it to bid just to block.
//      - Is this more like real MEV?

enum IncludeStatus {
    Reverted,
    Aborted,
    Included
}

enum Asset {
    Gold,
    Apples,
    Fish,
    Bread,
    Milk,
    Rugs
}

contract Market {
    using LibSafeCast for uint256;
    using LibSafeCast for int128;

    struct Pool {
        uint96 reserve0;
        uint96 reserve1;
    }

    // TODO: What are the consequences of no fee?

    Game public immutable GAME;
    mapping (address => mapping (Asset => uint256)) public balanceOf;
    mapping (Asset asset0 => mapping (Asset asset1 => Pool)) _poolsByAssets;

    modifier onlyActor() {
        require(msg.sender == GAME.currentActor());
        _;
    }

    modifier onlyGame() {
        require(msg.sender == address(GAME));
        _;
    }

    function quoteSell(Asset sellAsset, Asset buyAsset, uint256 sellAmount)
        public
        view
        returns (uint256 buyAmount)
    {
        (Asset asset0, Asset asset1) = _sortAssetPair(sellAsset, buyAsset);
        (uint96 reserve0, uint96 reserve1) = _getExistingPool(asset0, asset1);
        (int128 amount0, int128 amount1) = sellAsset == asset0
            ? (sellAmount.toInt128(), 0)
            : (0, sellAmount.toInt128());
        (amount0, amount1) = _quote(reserve0, reserve1, amount0, amount1);
        return sellAsset == asset0 ? (-amount1).toUint256() : (-amount0).toUint256();
    }

    function quoteBuy(Asset sellAsset, Asset buyAsset, uint256 buyAmount)
        public
        view
        returns (uint256 sellAmount)
    {
        (Asset asset0, Asset asset1) = _sortAssetPair(sellAsset, buyAsset);
        (uint96 reserve0, uint96 reserve1) = _getExistingPool(asset0, asset1);
        (int128 amount0, int128 amount1) = buyAsset == asset0
            ? (-buyAmount.toInt128(), 0)
            : (0, -buyAmount.toInt128());
        (amount0, amount1) = _quote(reserve0, reserve1, amount0, amount1);
        return sellAsset == asset0 ? (-amount1).toUint256() : (-amount0).toUint256();
    }

    function _quote(
        int128 reserve0,
        int128 reserve1,
        int128 amountIn0,
        int128 amountIn1
    )
        private
        pure
        returns (int128 amountOut0, int128 amountOut1)
    {
        assert(reserve0 > 0 && reserve0 > 0);
        int256 k = int256(reserve0) * int256(reserve1);
        if (amountIn0 != 0) {
            assert(amountIn1 == 0);
            amountOut1 = amountIn0 < 0
                ? divUp(k, reserve0 + amountIn0) - reserve1
                : reserve1 - k / (reserve0 + amountIn0);
        } else if (amountIn1 != 0) {
            amountOut0 = amountIn1 < 0
                ? divUp(k, reserve1 + amountIn1) - reserve0
                : reserve0 - k / (reserve1 + amountIn1);
        }
    }

    function sell(Asset sellAsset, Asset buyAsset, uint256 sellAmount)
        external
        onlyActor
        returns (uint256 buyAmount)
    {
        // ...
    }

    function _getExistingPool(Asset asset0, Asset asset1)
        private
        view
        returns (uint96 reserve0, uint96 reserve1)
    {
        Pool memory pool = _poolsByAssets[asset0][asset1];
        (reserve0, reserve1) = (pool.reserve0, pool.reserve1);
        require(reserve0 != 0);
    }

    function _sortAssetPair(Asset a, Asset b)
        private
        pure
        returns (Asset asset0, Asset asset1)
    {
        (asset0, asset1) = address(a) > address(b) ? (b, a) : (a, b);
    }

    function burn(Asset asset, address owner, uint256 amount)
        external
        onlyGame
    {
        balanceOf[owner][asset] -= amount;
    }

    function transfer(Asset asset, address to, uint256 amount) external onlyActor;
    function swap(Asset sellAsset, Asset buyAsset, uint256 sellAmount) external onlyActor returns (uint256 buyAmount);
}

contract Player {
    function act(address builder) external {
        market.swap(Asset.Apples, Asset.Gold, amt);
        market.transfer(Asset.Gold, builder, amount);
    }
}

contract Builder {
    // If this fails, all players get included?
    //  Incentive for other players to make this fail?
    function build(address[] players)
        external
        returns (uint256 bid)
    {
        (IncludeStatus status, bytes memory result) = game.include(player[0], data);
        if (status == IncludeStatus.Included) {

        }
        game.include(data);
        game.include(player[0], data);
        game.include(player[1], data);
        gane.include(data);
        return 100;
    }

    function afterInclude(player, data) external returns (bytes memory abortResult) {
        game.getMarket(APPLES_APPLES).quote(100);
        // ...
        return hex"...";
    }
}

library LibSafeCast {
    function toUint96(uint256 x) internal pure returns (uint96 y) {
        require(x <= type(uint96).max);
        return uint96(x);
    }

    function toInt128(uint256 x) internal pure returns (int128 y) {
        require(x <= uint128(type(int128).max));
        return int128(x);
    }

    function toUint256(int128 x) internal pure returns (uint256 y) {
        require(x >= 0);
        return uint128(x);
    }
}

function divUp(uint256 n, uint256 d) internal pure returns (uint256 q) {
    return (n + (d - 1)) / d;
}

// Implements NUM_POOLS AMM curves. Only supports one direction of trades:
// buying asset0 for asset1. Everytime a buy occurs on a pool, the "bought" asset0 is
// sold to the other (N-1) pools. This results in the price of asset0 increasing
// on the pool it was bought from and decreasing on the other pools.
contract LinkedPools {
    using LibSafeCast for uint256;

    struct PoolState {
        uint96 reserve0;
        uint96 reserve1;
        uint96 lastReserve0Accumulator;
    }
    
    address public immutable OPERATOR;
    uint32 public immutable NUM_POOLS;
    uint96 immutable INITIAL_RESERVE0;
    uint96 immutable INITIAL_RESERVE1;
    uint96 _reserve0Accumulator;
    mapping (uint32 poolId => PoolState state) _poolById;

    modifier onlyOperator() {
        require(msg.sender === OPERATOR);
        _;
    }

    modifier onlyValidPoolId(uint32 poolId) {
        require(poolId < NUM_POOLS);
        _;
    }

    constructor(
        address operator,
        uint96 initialReserve0,
        uint96 initialReserve1,
        uint32 numPools
    ) {
        require(initialReserve0 * initialReserve1 >= 1e4);
        OPERATOR = operator;
        NUM_POOLS = numPools;
        INITIAL_RESERVE0 = initialReserve0;
        INITIAL_RESERVE1 = initialReserve1;
    }

    function getPoolState(uint32 poolId)
        public
        view
        onlyValidPoolId(poolId)
        returns (uint96 reserve0, uint96 reserve1)
    {
        PoolState memory state = _poolById[poolId];
        if (state.reserve0 == 0) {
            // Uninitialized pool.
            assert(state.reserve1 == 0);
            (state.reserve0, state.reserve1) =
                (INITIAL_RESERVE0, INITIAL_RESERVE1);
        }
        uint96 reserve0Accumulator = _reserve0Accumulator;
        if (reserve0Accumulator > state.lastReserve0Accumulator) {
            // Sell any accumulated bought amount0s to this pool.
            uint96 amount0 =
                (reserve0Accumulator - state.lastReserve0Accumulator) / NUM_POOLS;
            uint256 k = uint256(state.reserve0) * uint256(state.reserve1);
            state.reserve0 += amount0;
            state.reserve1 = (k / state.reserve0).toUint96();
            assert(state.reserve1 != 0);
        }
        (reserve0, reserve1) = (state.reserve0, state.reserve1);
    }

    function delta1(uint32 poolId)
        external
        view
        returns (int256 delta1_)
    {
        (, uint96 reserve1) = getPoolState(poolId);
        return reserve1 - INITIAL_RESERVE1;
    }

    function quote0(uint32 poolId, uint256 amount0)
        external
        view
        returns (uint256 amount1)
    {
        (uint96 reserve0, uint96 reserve1) = getPoolState(poolId);
        return _quote0(reserve0, reserve1);
    }

    function _quote0(uint96 reserve0, uint96 reserve1, uint96 amount0)
        internal
        view
        returns (uint96 amount1)
    {
        (uint256 reserve0, uint256 reserve1) = (state.reserve0, state.reserve1);
        require(amount0 < reserve0);
        uint256 k = reserve0 * reserve1;
        return divUp(k, reserve0 - amount0).toUint96() - reserve1;
    }

    function buy0(uint32 poolId, uint256 amount0)
        external
        onlyOperator
        returns (uint256 amount1)
    {
        (uint96 reserve0, uint96 reserve1) = getPoolState(poolId);
        uint96 amount0_ = amount0.toUint96();
        uint96 amount1_ = _quote0(reserve0, reserve1, amount0_);
        reserve0 -= amount0_;
        reserve1 += amount1_;
        require(reserve1 != 0);
        // Spread amount0 across the other pools by adding it to the accumulator.
        _poolById[poolId] = PoolState({
            reserve0: reserve0,
            reserve1: reserve1,
            lastReserve0Accumulator: _reserve0Accumulator += amount0_
        });
        return amount1_;
    }
}

contract Game {
    uint256 _gasUsedByAllPlayers;
    mapping (address => uint256) _gasUsedByPlayer;
    address public currentActor;
    uint256 public round; 
    address _currentBuilder;
    address[] _players;

    modifier onlyCurrentBuilder() {
        require(msg.sender == _currentBuilder);
        _;
    }

    modifier notActing() {
        require(currentActor == address(0));
        _;
    }

    function playRound() external onlyGameMaster {
        uint256 maxBid;
        uint256 bidWinner;
        address[] memory players = _players;
        for (uint256 i = 0; i < players.length; ++i) {
            address player = players[i];
            uint256 bid;
            try this.__buildAndRevert(player) {
                assert(false);
            } catch (bytes memory err) {
                if (err.length == 32) {
                    bid = abi.decode(err, (uint256))
                }
            }
            if (bid != 0 && bid > maxBid)  {
                maxBid = bid; 
                bidWinner = player;
            }
        }
        if (bidWinner != address(0)) {
            assert(_callBuild(bidWinner) == maxBid);
        } else (!blockBuilt) {
            // No builder or builder failed. EVeryone gets in.
            for (uint256 i = 0; i < players.length; ++i) {
                players[i].include(players[i], "");
            }
        }
        ++round;
    }

    function include(bytes memory data)
        external
        onlyCurrentBuilder
        notActing 
    {
        this.__act(player, builder, true);
    }

    function include(address player, bytes memory data)
        external
        onlyCurrentBuilder
        notActing 
        returns (IncludeStatus status, bytes memory result)
    {
        try 
            this.__include(msg.sender, player, data, false)
                returns (bytes memory includeData) {
            return (IncludeStatus.Included, includeData);
        } catch (bytes memory errData) {
            IncludeStatus status = abi.decode(errData, (IncludeStatus));
            if (status == IncludeStatus.Reverted) {
                return (status, "");
            }
            if (status == IncludeStatus.Aborted) {
                return abi.decode(errData, (IncludeStatus, bytes));
            }
        }
    }

    function __buildAndRevert(address builder) external onlySelf {
        uint256 bid = _callBuild()
        if (bid == 0) {
            revert("");
        }
        assembly ("memory-safe") {
            mstore(0x00, bid)
            revert(0x00, 0x00)
        }
    }

    function _callBuild(address builder) private returns (uint256 bid) {
        _currentBuilder = bidWinner;
        {
            bytes memory callData = abi.encodeCall(build, (players));
            assembly ("memory-safe")  {
                let s := call(MAX_BUILD_GAS, builder, 0, add(callData, 0x20), mload(callData), 0, 0x20)
                if s {
                    bid = mload(0x00)
                }
            }
        }
        if (bid != 0) {
            try MARKET.burn(Asset.Gold, builder, bid) {}
            catch { bid = 0; }
        }
    }

    function __include(address builder, address player, bytes memory data)
        external
        onlySelf
        returns (bytes memory result)
    {
        require(!included[round][player]);
        included[round][player] = true;
        try {
            this.__act(player, builder);
        } catch {
            abi.encode(IncludeStatus.Reverted).rawRevert();
        }
    
        if (builder != player && builder != address(this)) {
            bytes memory abortResult = Builder(builder).afterInclude(player, data);
            if (abortResult.length > 0) {
                abi.encode(IncludeStatus.Aborted, data).rawRevert();
            }
        }
        
        // What if gas consumed just counted against the player's final score?
        // Like you get penalized based on what % of total combined gas was consumed by
        // all parties? 
        emit Included(builder, player);
    }

    function __act(address player, address builder, bool bubbleRevert)
        external
        notActing
        onlySelf
    {
        currentActor = player;
        bytes memory callData = abi.encodeCall(Player.act, (builder));
        uint256 gasUsed = gasleft();
        assembly ("memory-safe") {
            let s := call(MAX_ACTION_GAS, player, 0, add(callData, 0x20), mload(callData), 0, 0)
            if iszero(s) {
                if iszero(bubbleRevert) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
                revert(0, 0)
            }
            gasUsed := sub(gasUsed, gas()) 
        }
        _gasUsedByAllPlayers += gasUsed;
        _gasUsedByPlayer[player] += gasUsed;
        currentActor = address(0); 
    }
}