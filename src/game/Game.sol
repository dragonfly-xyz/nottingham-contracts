// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { AssetMarket } from './Markets.sol';
import { LibBytes } from './LibBytes.sol';
import { LibAddress } from './LibAddress.sol';
import { IPlayer, PlayerBundle, SwapSell } from './IPlayer.sol';
import { SafeCreate2 } from './SafeCreate2.sol';

IPlayer constant NULL_PLAYER = IPlayer(address(0));
uint160 constant PLAYER_ADDRESS_INDEX_MASK = 7;
uint8 constant GOLD_IDX = 0;
uint256 constant MIN_PLAYERS = 2;
// Bounded by size of address suffix.
uint256 constant MAX_PLAYERS = 8;
uint8 constant MAX_ROUNDS = 64;
uint256 constant MIN_WINNING_ASSET_BALANCE = 64e18;
uint256 constant MARKET_STARTING_GOLD_PER_PLAYER = 32e18;
uint256 constant MARKET_STARTING_GOODS_PER_PLAYER = 32e18;
uint8 constant INVALID_PLAYER_IDX = type(uint8).max;
uint256 constant MAX_CREATION_GAS = 200 * 0x8000 + 1e6;
uint256 constant TURN_GAS_BASE = 1e6;
uint256 constant TURN_GAS_PER_PLAYER = 500e3;
uint256 constant BUILD_GAS_BASE = 4e6;
uint256 constant BUILD_GAS_PER_PLAYER = 1e6;
uint256 constant MAX_RETURN_DATA_SIZE = 1024;
uint256 constant INCOME_AMOUNT = 1e18;
uint256 constant MIN_GAS_PER_BUNDLE_SWAP = 50e3;

function getIndexFromPlayer(IPlayer player) pure returns (uint8 playerIdx) {
    // The deployment process in the constructor ensures that the lowest 3 bits of the
    // player's address is also its player index.
    return uint8(uint160(address(player)) & PLAYER_ADDRESS_INDEX_MASK);
}

function getBundleHash(PlayerBundle memory bundle, uint16 round)
    pure returns (bytes32 hash)
{
    return bytes32((uint256(keccak256(abi.encode(bundle))) & ~uint256(0xFFFF)) | round);
}

function getRoundFromBundleHash(bytes32 hash) pure returns (uint16 round) {
    return uint16(uint256(hash) & 0xFFFF);
}

contract Game is AssetMarket {
    using LibBytes for bytes;
    using LibAddress for address;

    uint256 constant PLAYER_BUNDLE_HASH_TSLOT = 1;

    address public immutable gm;
    uint8 public immutable playerCount;
    uint16 internal _round;
    bool _inRound;
    IPlayer _builder;
    uint256 public lastWinningBid;
    mapping (uint8 playerIdx => mapping (uint8 assetIdx => uint256 balance)) public balanceOf;
    mapping (uint8 playerIdx => IPlayer player) internal  _playerByIdx;

    error GameOverError();
    error GameSetupError(string msg);
    error AccessError();
    error AlreadyInRoundError();
    error DuringBlockError();
    error InsufficientBalanceError(uint8 playerIdx, uint8 assetIdx);
    error InvalidPlayerError();
    error BundleNotSettledError(uint8 builderIdx, uint8 playerIdx);
    error BuildBlockFailedError(uint8 builderIdx, bytes revertData);
    error OnlySelfError();
    error TooManySwapsError();
    error SlippageError(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount, uint256 minToAmount, uint256 actualToAmount);
    error BundleAlreadySettledError(uint8 playerIdx);
    error BuildPlayerBlockAndRevertSuccess(uint256 bid);
    error InsufficientBundleGasError();
    
    event CreatePlayerFailed(uint8 playerIdx);
    event RoundPlayed(uint16 round);
    event PlayerCreateBundleFailed(uint8 playerIdx, uint8 builderIdx, bytes revertData);
    event Mint(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount);
    event Burn(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount);
    event Transfer(uint8 fromPlayerIdx, uint8 toPlayerIdx, uint8 assetIdx, uint256 assetAmount);    
    event BlockBid(uint8 builderIdx, uint256 bid);
    event BlockBuilt(uint16 round, uint8 builderIdx, uint256 bid);
    event EmptyBlock(uint16 round);
    event BuildPlayerBlockFailed(uint8 builderIdx, bytes data);
    event Swap(uint8 playerIdx, uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount, uint256 toAmount);
    event GameOver(uint16 rounds, uint8 winnerIdx); 
    event PlayerBlockGasUsage(uint8 builderIdx, uint256 gasUsed);
    event BundleSettled(uint8 playerIdx, bool success, PlayerBundle bundle);

    modifier onlyGameMaster() {
        if (msg.sender != gm) revert AccessError();
        _;
    }
   
    modifier onlyBuilder() {
        if (msg.sender != address(_builder)) revert AccessError();
        _;
    }
   
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelfError();
        _;
    }
   
    constructor(
        address gameMaster,
        SafeCreate2 sc2,
        bytes[] memory playerCreationCodes,
        uint256[] memory deploySalts
    )
        AssetMarket(uint8(playerCreationCodes.length)) // num Assets = player count
    {
        if (playerCreationCodes.length != deploySalts.length) {
            revert GameSetupError('mismatched arrays');
        }
        gm = gameMaster;
        playerCount = uint8(playerCreationCodes.length);
        if (playerCount < MIN_PLAYERS || playerCount > MAX_PLAYERS) {
            revert GameSetupError('# of players');
        }
        playerCount = uint8(playerCreationCodes.length);
        {
            bytes memory initArgs = abi.encode(0, playerCount);
            for (uint8 i; i < playerCount; ++i) {
                assembly ('memory-safe') { mstore(add(initArgs, 0x20), i) }

                IPlayer player;
                try sc2.safeCreate2{gas: MAX_CREATION_GAS}(
                    playerCreationCodes[i],
                    deploySalts[i],
                    initArgs
                ) returns (address player_) {
                    player = IPlayer(player_);
                } catch {
                    // Assign to empty player address.
                    player = IPlayer(address((255 & (~PLAYER_ADDRESS_INDEX_MASK)) | i));
                    emit CreatePlayerFailed(i);
                }
                // The lowest uint8 of each deployed address should also hold the player index.
                if (uint160(address(player)) & PLAYER_ADDRESS_INDEX_MASK != i) {
                    revert GameSetupError('player index');
                }
                _playerByIdx[i] = player;
            }
        }
        {
            // There will be nplayer assets (incl gold) in the market to ensure
            // at least one asset will be in contention.
            uint8 assetCount_ = uint8(ASSET_COUNT);
            uint256[] memory assetReserves = new uint256[](assetCount_);
            assetReserves[GOLD_IDX] = MARKET_STARTING_GOLD_PER_PLAYER * playerCount;
            for (uint8 i = 1; i < assetCount_; ++i) {
                assetReserves[i] = MARKET_STARTING_GOODS_PER_PLAYER * playerCount;
            }
            AssetMarket._init(assetReserves);
        }
    }

    function findWinner() external view returns (uint8 winnerIdx) {
        IPlayer winner = _findWinner(_round);
        return winner == NULL_PLAYER ? INVALID_PLAYER_IDX : getIndexFromPlayer(winner);
    }

    function scorePlayers() external view returns (uint256[] memory scores) {
        scores = new uint256[](playerCount);
        for (uint8 playerIdx; playerIdx < scores.length; ++playerIdx) {
            (, scores[playerIdx]) = _getMaxNonGoldAssetForPlayer(playerIdx);
        }
    }

    function round() public view returns (uint16 round_) {
        return _getTrueRoundCount(_round);
    }

    function assetCount() external view returns (uint8) {
        return ASSET_COUNT;
    }

    function isGameOver() public view returns (bool) {
        return _round >= MAX_ROUNDS;
    }

    function quoteSell(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        external view returns (uint256 toAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        return AssetMarket._quoteSell(fromAssetIdx, toAssetIdx, fromAmount);
    }

    function quoteBuy(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        external view returns (uint256 fromAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        return AssetMarket._quoteBuy(fromAssetIdx, toAssetIdx, toAmount);
    }

    function marketState() external view returns (uint256[] memory reserves) {
        reserves = new uint256[](ASSET_COUNT);
        for (uint8 assetIdx; assetIdx < ASSET_COUNT; ++assetIdx) {
            reserves[assetIdx] = AssetMarket._getReserve(assetIdx);
        }
        return reserves;
    }

    function playRound() external onlyGameMaster returns (uint8 winnerIdx) {
        if (_inRound) revert AlreadyInRoundError();
        _inRound = true;
        uint16 round_ = _round;
        if (round_ >= MAX_ROUNDS) revert GameOverError();
        _distributeIncome();
        _buildBlock();
        emit RoundPlayed(round_);
        {
            IPlayer winner = _findWinner(round_);
            if (winner != NULL_PLAYER) {
                winnerIdx = getIndexFromPlayer(winner);
                // Invert the round counter to end the game early.
                _round = (round_ = ~(++round_));
                assert(round_ >= MAX_ROUNDS);
            } else {
                winnerIdx = INVALID_PLAYER_IDX;
                _round = ++round_;
            }
        }
        _inRound = false;
        if (winnerIdx != INVALID_PLAYER_IDX) {
            emit GameOver(_getTrueRoundCount(round_), winnerIdx);
        }
    }

    function sell(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        external onlyBuilder returns (uint256 toAmount)
    {
        // Caller must be builder, which is always a valid player.
        uint8 playerIdx = getIndexFromPlayer(IPlayer(msg.sender));
        return _sellAs(playerIdx, fromAssetIdx, toAssetIdx, fromAmount);
    }

    function buy(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        external onlyBuilder returns (uint256 fromAmount)
    {
        // Caller must be builder, which is always a valid player.
        uint8 playerIdx = getIndexFromPlayer(IPlayer(msg.sender));
        return _buyAs(playerIdx, fromAssetIdx, toAssetIdx, toAmount);
    }

    function buildPlayerBlockAndRevert(uint8 builderIdx)
        external onlySelf
    {
        revert BuildPlayerBlockAndRevertSuccess(_buildPlayerBlock(builderIdx));
    }

    function settleBundle(uint8 playerIdx, PlayerBundle memory bundle)
        external onlyBuilder returns (bool success)
    {
        if (playerIdx >= playerCount) revert InvalidPlayerError();
        {
            uint16 round_ = _round;
            {
                bytes32 lastHash = _getPlayerLastBundleHash(playerIdx);
                if (lastHash != 0 && getRoundFromBundleHash(lastHash) == round_) {
                    revert BundleAlreadySettledError(playerIdx);
                }
            }
            _setPlayerLastBundleHash(playerIdx, getBundleHash(bundle, round_));
        }
        if (gasleft() < MIN_GAS_PER_BUNDLE_SWAP * bundle.swaps.length + 2e3) {
            revert InsufficientBundleGasError();
        }
        try this.selfSettleBundle(playerIdx, bundle) {
            success = true;
        } catch {}
        emit BundleSettled(playerIdx, success, bundle);
        return success;
    }

    // Only called by settle().
    function selfSettleBundle(uint8 playerIdx, PlayerBundle memory bundle)
        external onlySelf
    {
        for (uint256 i; i < bundle.swaps.length; ++i) {
            SwapSell memory swap = bundle.swaps[i];
            uint256 toAmount = _sellAs(playerIdx, swap.fromAssetIdx, swap.toAssetIdx, swap.fromAmount);
            if (toAmount < swap.minToAmount) {
                revert SlippageError(swap.fromAssetIdx, swap.toAssetIdx, swap.fromAmount, swap.minToAmount, toAmount);
            }
        }
        if (bundle.builderGoldTip != 0) {
            _transfer(playerIdx, getIndexFromPlayer(IPlayer(msg.sender)), GOLD_IDX, bundle.builderGoldTip);
        }
    }

    function _findWinner(uint16 round_)
        internal virtual view returns (IPlayer winner)
    {
        // Find which player has the maximum balance of any asset that isn't gold.
        uint8 maxBalancePlayerIdx;
        uint8 maxBalanceAssetIdx;
        uint256 maxBalance;
        for (uint8 playerIdx; playerIdx < playerCount; ++playerIdx) {
           (uint8 assetIdx, uint256 assetBalance) = _getMaxNonGoldAssetForPlayer(playerIdx);
            if (assetBalance > maxBalance) {
                maxBalancePlayerIdx = playerIdx;
                maxBalanceAssetIdx = assetIdx;
                maxBalance = assetBalance;
            }
        }
        if (round_ < MAX_ROUNDS) {
            // If not at max rounds, the winner is whomever has at least the minimum
            // winning asset balance.
            if (maxBalanceAssetIdx != 0 && maxBalance >= MIN_WINNING_ASSET_BALANCE) {
                return _playerByIdx[maxBalancePlayerIdx];
            }
            return NULL_PLAYER;
        }
        return _playerByIdx[maxBalancePlayerIdx];
    }

    function _getMaxNonGoldAssetForPlayer(uint8 playerIdx)
        internal view returns (uint8 assetIdx, uint256 balance)
    {
        uint8 nAssets = ASSET_COUNT;
        for (assetIdx = GOLD_IDX + 1; assetIdx < nAssets; ++assetIdx) {
            uint256 bal = balanceOf[playerIdx][assetIdx];
            if (bal > balance) {
                assetIdx = assetIdx;
                balance = bal;
            }
        }
    }

    function _getTrueRoundCount(uint16 rawRound) private pure returns (uint16 round_) {
        return rawRound & 0x8000 != 0 ? ~rawRound : rawRound;
    }

    function _assertValidAsset(uint8 assetIdx) private view {
        if (assetIdx >= ASSET_COUNT) revert InvalidAssetError();
    }


    function _getPlayerLastBundleHash(uint8 playerIdx) private view returns (bytes32 hash) {
        assembly ('memory-safe') {
            mstore(0x00, PLAYER_BUNDLE_HASH_TSLOT)
            hash := tload(add(keccak256(0x00, 0x20), playerIdx))
        }
    }

    function _getPlayerBundles(uint8 builderIdx)
        internal returns (PlayerBundle[] memory bundles)
    {
        uint8 n = playerCount;
        bundles = new PlayerBundle[](n);
        for (uint8 playerIdx; playerIdx < n; ++playerIdx) {
            if (builderIdx == playerIdx) {
                // Builder doesn't need a bundle.
                continue;
            }
            try this.selfCallPlayerCreateBundle(playerIdx, builderIdx)
                returns (PlayerBundle memory bundle)
            {
                bundles[playerIdx] = bundle;
            } catch (bytes memory errData) {
                emit PlayerCreateBundleFailed(playerIdx, builderIdx, errData);
                continue;
            }
        }
    }

    function _simulateBuildPlayerBlock(uint8 builderIdx)
        internal returns (uint256 bid)
    {
        uint256 gasUsed = gasleft();
        try this.buildPlayerBlockAndRevert(builderIdx) {
            // Call must revert.
            assert(false);
        } catch (bytes memory data) {
            gasUsed -= gasleft(); 
            emit PlayerBlockGasUsage(builderIdx, gasUsed);
            bytes4 selector = data.getSelectorOr(bytes4(0));
            if (selector == BuildPlayerBlockAndRevertSuccess.selector) {
                data = data.trimLeadingBytesDestructive(4);
                bid = abi.decode(data, (uint256));
            } else {
                emit BuildPlayerBlockFailed(builderIdx, data);
            }
        }
    }

    function _buildPlayerBlock(uint8 builderIdx)
        internal returns (uint256 bid)
    {
        IPlayer builder = _playerByIdx[builderIdx];
        assert(_builder == NULL_PLAYER);
        _builder = builder;
        PlayerBundle[] memory bundles = _getPlayerBundles(builderIdx);
        {
            bool success;
            bytes memory errData;
            (success, bid, errData) = _safeCallPlayerBuild(builder, bundles);
            if (!success) {
                revert BuildBlockFailedError(builderIdx, errData);
            }
        }
        // All player bundles must be executed (excluding the builder's).
        uint16 round_ = _round;
        for (uint8 playerIdx; playerIdx < bundles.length; ++playerIdx) {
            if (playerIdx != builderIdx) {
                if (_getPlayerLastBundleHash(playerIdx) != getBundleHash(bundles[playerIdx], round_)) {
                    revert BundleNotSettledError(builderIdx, playerIdx);
                }
            }
        }
        _burn(builderIdx, GOLD_IDX, bid);
        _builder = NULL_PLAYER;
    }

    function _safeCallPlayerBuild(IPlayer builder, PlayerBundle[] memory bundles)
        internal returns (bool success, uint256 bid, bytes memory errData)
    {
        bytes memory resultData;
        (success, resultData) = address(builder).safeCall(
            abi.encodeCall(IPlayer.buildBlock, (bundles)),
            false,
            BUILD_GAS_BASE + BUILD_GAS_PER_PLAYER * playerCount,
            MAX_RETURN_DATA_SIZE
        );
        if (!success || resultData.length != 32) {
            errData = resultData;
        } else {
            bid = abi.decode(resultData, (uint256));
        }
    }

    function selfCallPlayerCreateBundle(uint8 playerIdx, uint8 builderIdx)
        external onlySelf returns (PlayerBundle memory bundle)
    {
        IPlayer player = _playerByIdx[playerIdx];
        (bool success, bytes memory resultData) = address(player).safeCall(
            abi.encodeCall(IPlayer.createBundle, (builderIdx)),
            false,
            TURN_GAS_BASE + TURN_GAS_PER_PLAYER * playerCount,
            MAX_RETURN_DATA_SIZE
        );
        if (!success) {
            resultData.rawRevert();
        } else {
            bundle = abi.decode(resultData, (PlayerBundle));
            if (bundle.swaps.length > ASSET_COUNT - 1) {
                revert TooManySwapsError();
            }
        }
    }

    function _auctionBlock()
        internal virtual returns (uint8 builderIdx, uint256 builderBid)
    {
        builderIdx = INVALID_PLAYER_IDX;
        for (uint8 i; i < playerCount; ++i) {
            uint256 bid = _simulateBuildPlayerBlock(i);
            if (bid != 0) {
                emit BlockBid(i, bid);
                if (bid > builderBid) {
                    builderBid = bid;
                    builderIdx = i;
                }
            }
        }
    }

    function _buildBlock() internal {
        (uint8 builderIdx, uint256 builderBid) = _auctionBlock();
        if (builderBid != 0) {
            assert(_buildPlayerBlock(builderIdx) == builderBid);
            lastWinningBid = builderBid;
            emit BlockBuilt(_round, builderIdx, builderBid);
        } else {
            emit EmptyBlock(_round);
        }
    }

    function _distributeIncome() internal virtual {
        uint8 numAssets = ASSET_COUNT;
        // Mint 1 unit of each type of asset to each player.
        for (uint8 playerIdx; playerIdx < playerCount; ++playerIdx) {
            for (uint8 assetIdx; assetIdx < numAssets; ++assetIdx) {
                _mint({playerIdx: playerIdx, assetIdx: assetIdx, assetAmount: INCOME_AMOUNT});
            }
        }
    }

    function _mint(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) internal {
        balanceOf[playerIdx][assetIdx] += assetAmount;
        emit Mint(playerIdx, assetIdx, assetAmount);
    }

    function _burn(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) internal {
        uint256 bal = balanceOf[playerIdx][assetIdx];
        if (bal < assetAmount) revert InsufficientBalanceError(playerIdx, assetIdx);
        unchecked {
            balanceOf[playerIdx][assetIdx] = bal - assetAmount;
        }
        emit Burn(playerIdx, assetIdx, assetAmount);
    }

    function _transfer(uint8 fromPlayerIdx, uint8 toPlayerIdx, uint8 assetIdx, uint256 amount)
        internal
    {
        uint256 fromBal = balanceOf[fromPlayerIdx][assetIdx];
        if (fromBal < amount) revert InsufficientBalanceError(fromPlayerIdx, assetIdx);
        unchecked {
            balanceOf[fromPlayerIdx][assetIdx] = fromBal - amount;
            balanceOf[toPlayerIdx][assetIdx] += amount;
        }
        emit Transfer(fromPlayerIdx, toPlayerIdx, assetIdx, amount);
    }

    function _setPlayerLastBundleHash(uint8 playerIdx, bytes32 hash) private {
        assembly ('memory-safe') {
            mstore(0x00, PLAYER_BUNDLE_HASH_TSLOT)
            tstore(add(keccak256(0x00, 0x20), playerIdx), hash)
        }
    }

    function _sellAs(uint8 playerIdx, uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        internal returns (uint256 toAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        _burn(playerIdx, fromAssetIdx, fromAmount);
        toAmount = AssetMarket._sell(fromAssetIdx, toAssetIdx, fromAmount);
        _mint(playerIdx, toAssetIdx, toAmount);
        emit Swap(playerIdx, fromAssetIdx, toAssetIdx, fromAmount, toAmount);
    }

    function _buyAs(uint8 playerIdx, uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        internal returns (uint256 fromAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        fromAmount = AssetMarket._buy(fromAssetIdx, toAssetIdx, toAmount);
        _burn(playerIdx, fromAssetIdx, fromAmount);
        _mint(playerIdx, toAssetIdx, toAmount);
        emit Swap(playerIdx, fromAssetIdx, toAssetIdx, fromAmount, toAmount);
    }
}
