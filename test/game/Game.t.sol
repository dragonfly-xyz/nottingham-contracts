// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Vm, Test } from "forge-std/Test.sol";
import { LibTestUtils as T } from "../LibTestUtils.sol";
import {
    Game,
    NULL_PLAYER,
    getIndexFromPlayer,
    MAX_PLAYERS,
    MAX_ROUNDS,
    MIN_WINNING_ASSET_BALANCE,
    GOLD_IDX,
    INVALID_PLAYER_IDX,
    GOLD_INCOME_AMOUNT,
    GOODS_INCOME_AMOUNT,
    PLAYER_BUILD_BLOCK_GAS_BASE,
    PLAYER_BUILD_BLOCK_GAS_PER_PLAYER,
    MIN_GAS_PER_BUNDLE_SWAP
} from "~/game/Game.sol";
import { AssetMarket } from "~/game/Markets.sol";
import { IPlayer, PlayerBundle, SwapSell } from "~/game/IPlayer.sol";
import { LibBytes } from "~/game/LibBytes.sol";
import { LibMatchUtils } from "~/game/LibMatchUtils.sol";
import { SafeCreate2 } from "~/game/SafeCreate2.sol";

using LibBytes for bytes;

event PlayerCreated(address self, uint8 playerIdx, uint8 playerCount);
event Bundling(uint8 builderIdx);
event Building(PlayerBundle[] bundles);
error TestError();

uint8 constant MOCK_UNSET_PLAYER_IDX = INVALID_PLAYER_IDX - 1;
bytes32 constant CREATE_BUNDLE_STATE_EVENT_SIGNATURE = keccak256('CreateBundleState(uint8,uint8,bytes32)');
bytes32 constant BUILD_BLOCK_STATE_EVENT_SIGNATURE = keccak256('BuildBlockState(uint8,bytes32)');

function isAddressCold(address addr) view returns (bool isCold) {
    assembly ("memory-safe") {
        let g := gas()
        pop(staticcall(gas(), addr, 0, 0, 0, 0))
        g := sub(g, gas())
        isCold := gt(g, 200)
    }
}

contract GameTest is Test {
    SafeCreate2 sc2 = new SafeCreate2();

    function revertBack(bytes memory revertData) external pure {
        revertData.rawRevert();
    }

    function throwInvalid() external pure {
        T.throwInvalid();
    }

    function test_deploysPlayersWithArgs() external {
        address gameAddress = _getNextDeployAddress();
        uint256 playerCount = T.randomUint256() % 5 + 2;
        bytes[] memory creationCodes = new bytes[](playerCount);
        for (uint256 i; i < playerCount; ++i) {
            creationCodes[i] = type(NoopPlayer).creationCode;
        }
        (uint256[] memory salts, IPlayer[] memory players) = _minePlayers(Game(gameAddress), creationCodes);
        for (uint256 i; i < playerCount; ++i) {
            assertEq(uint160(address(players[i])) & 7, i);
            vm.expectEmit(true, true, true, true);
            emit PlayerCreated(address(players[i]), uint8(i), uint8(playerCount));
        }
        Game game = new Game(address(this), sc2, creationCodes, salts);
        assertEq(address(game), gameAddress); 
    }

    function test_createsNAssets() external {
        uint256 playerCount = T.randomUint256() % 5 + 2;
        bytes[] memory creationCodes = new bytes[](playerCount);
        for (uint256 i; i < playerCount; ++i) {
            creationCodes[i] = type(NoopPlayer).creationCode;
        }
        (Game game,) = _createGame(creationCodes);
        assertEq(game.assetCount(), playerCount);
    }

    function test_cannotDeployGameWithLessThanTwoPlayers() external {
        bytes[] memory creationCodes = new bytes[](1);
        uint256[] memory salts = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(address(this), sc2, creationCodes, salts);
    }

    function test_cannotDeployGameWithMoreThanEightPlayers() external {
        bytes[] memory creationCodes = new bytes[](9);
        uint256[] memory salts = new uint256[](9);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(address(this), sc2, creationCodes, salts);
    }

    function test_canDeployGameWithFailingPlayerInitCode() external {
        bytes[] memory creationCodes = new bytes[](2);
        creationCodes[0] = hex'fe';
        (uint256[] memory salts, ) = _minePlayers(Game(_getNextDeployAddress()), creationCodes);
        vm.expectEmit(true, true, true, true);
        emit Game.CreatePlayerFailed(0);
        new Game(address(this), sc2, creationCodes, salts);
    }
    
    function test_canPlayRoundWithRevertingPlayers() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        bytes memory callRevertData = abi.encodeCall(this.revertBack, (''));
        for (uint256 i = 0; i < players.length; ++i) {
            TestPlayer(address(players[i])).addCallback(
                IPlayer.createBundle.selector,
                address(this),
                callRevertData
            );
            TestPlayer(address(players[i])).addCallback(
                IPlayer.buildBlock.selector,
                address(this),
                callRevertData
            );
        }
        uint8 winnerIdx = game.playRound();
        assertEq(winnerIdx, INVALID_PLAYER_IDX);
    }

    function test_canPlayRoundWithEmptyAndRevertingPlayers() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(EmptyContract).creationCode,
            hex'fe'
        ]));
        uint8 winnerIdx = game.playRound();
        assertEq(winnerIdx, INVALID_PLAYER_IDX);
    }

    function test_gameEndsWithNoopPlayers() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx;
        while (true) {
            winnerIdx = game.playRound();
            if (winnerIdx != INVALID_PLAYER_IDX) break;
        }
        assertEq(winnerIdx, 0);
        (uint8 assetIdx, uint256 bal) = _getMaxNonGoldAssetBalance(game, winnerIdx);
        assertTrue(assetIdx != GOLD_IDX);
        assertLt(bal, MIN_WINNING_ASSET_BALANCE);
        assertTrue(game.isGameOver());
    }

    function test_cannotPlayAnotherRoundAfterWinnerDeclared() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx = _getRandomPlayerIdx(game);
        game.setMockWinner(winnerIdx);
        assertEq(game.findWinner(), winnerIdx);
        assertFalse(game.isGameOver());
        game.playRound();
        vm.expectRevert(Game.GameOverError.selector);
        game.playRound();
    }

    function test_gameEndsEarlyIfWinnerFound() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx = _getRandomPlayerIdx(game);
        game.setMockWinner(winnerIdx);
        assertEq(game.playRound(), winnerIdx);
        assertTrue(game.isGameOver());
    }

    function test_distributeIncome_givesAssetsToEveryPlayer() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 playerCount = game.playerCount();
        uint8 assetCount = game.assetCount();
        for (uint8 playerIdx; playerIdx < playerCount; ++playerIdx) {
            for (uint8 assetIdx; assetIdx < assetCount; ++assetIdx) {
                assertEq(game.balanceOf(playerIdx, assetIdx), 0);
            }
        }
        game.__distributeIncome();
        for (uint8 playerIdx; playerIdx < playerCount; ++playerIdx) {
            for (uint8 assetIdx; assetIdx < assetCount; ++assetIdx) {
                assertEq(
                    game.balanceOf(playerIdx, assetIdx),
                    assetIdx == GOLD_IDX ? GOLD_INCOME_AMOUNT : GOODS_INCOME_AMOUNT
                );
            }
        }
    }

    function test_findWinner_whenBelowMaxRoundsAndPlayerHasWinningBalanceOfANonGoldAsset_returnsThatPlayer() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx = _getRandomPlayerIdx(game);
        game.setRound(MAX_ROUNDS - 1);
        uint8 assetIdx = _getRandomNonGoldAssetIdx(game);
        game.mint(winnerIdx, assetIdx, MIN_WINNING_ASSET_BALANCE);
        assertEq(game.findWinner(), winnerIdx);
    }

    function test_findWinner_whenBelowMaxRoundsAndNoPlayerHasWinningBalanceOfANonGoldAsset_returnsNoWinner() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS - 1);
        uint8 nonWinnerIdx = _getRandomPlayerIdx(game);
        uint8 assetIdx = _getRandomNonGoldAssetIdx(game);
        game.mint(nonWinnerIdx, assetIdx, MIN_WINNING_ASSET_BALANCE - 1);
        assertEq(game.findWinner(), INVALID_PLAYER_IDX);
    }

    function test_findWinner_whenAtMaxRoundsAndNoPlayerHasWinningBalanceOfANonGoldAsset_returnsPlayerWithMaxBalance() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS);
        uint8 winnerIdx = _getRandomPlayerIdx(game);
        uint8 assetIdx = _getRandomNonGoldAssetIdx(game);
        game.mint(winnerIdx, assetIdx, MIN_WINNING_ASSET_BALANCE - 1);
        assertEq(game.findWinner(), winnerIdx);
    }

    function test_findWinner_whenAtMaxRoundsAndEveryPlayerHasZeroOfANonGoldAsset_returnsFirstPlayer() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS);
        assertEq(game.findWinner(), 0);
    }

    function test_buildBlock_bidWinnerBuildsBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        builder.setBid(1337);
        game.setMockBlockAuctionWinner(builderIdx, 1337);
        game.mint(builderIdx, GOLD_IDX, 1338);
        vm.expectEmit(true, true, true, true, address(builder));
        emit Building(new PlayerBundle[](players.length));
        game.__buildBlock();
        assertEq(game.balanceOf(builderIdx, GOLD_IDX), 1);
    }

    // Normally this state is unreachable because the auction will invalidate the bid.
    function test_buildBlock_failsIfBidWinnerHasInsufficientFunds() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        builder.setBid(1337);
        game.setMockBlockAuctionWinner(builderIdx, 1337);
        game.mint(builderIdx, GOLD_IDX, 1336);
        vm.expectRevert(abi.encodeWithSelector(
            Game.InsufficientBalanceError.selector,
            builderIdx,
            GOLD_IDX
        ));
        game.__buildBlock();
    }

    function test_buildBlock_DoesNothingIfWinningBidIsZero() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
       game.setMockBlockAuctionWinner(INVALID_PLAYER_IDX, 0) ;
        vm.expectEmit(true, true, true, true);
        emit Game.EmptyBlock(0);
        game.__buildBlock();
    }

    function test_buildBlock_buildsPlayerBlockIfWinningBidIsNonZero() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        builder.setBid(1);
        game.mint(builderIdx, GOLD_IDX, 1);
        game.setMockBlockAuctionWinner(builderIdx, 1);
        vm.expectEmit(true, true, true, true);
        emit Game.BlockBuilt(0, builderIdx, 1);
        game.__buildBlock();
        assertEq(game.lastWinningBid(), 1);
    }

    // This state should be unreachable under normal conditions because the auction
    // process will filter out this activity.
    function test_buildBlock_panicsIfBuilderBidsWithDifferentBidThanAuction() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        builder.setBid(1337);
        game.setMockBlockAuctionWinner(builderIdx, 1336);
        vm.expectRevert();
        game.__buildBlock();
    }
    
    function test_buildPlayerBlock_failsIfSettlingTwice() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        // Add an extra settleBundle() call for player 0.
        builder.addCallback(IPlayer.buildBlock.selector, address(game), abi.encodeCall(
            Game.settleBundle,
            (0, PlayerBundle(new SwapSell[](0)))
        ));
        vm.expectRevert(abi.encodeWithSelector(
            Game.BuildBlockFailedError.selector,
            builderIdx,
            abi.encodeWithSelector(
                Game.BundleAlreadySettledError.selector,
                0
            )
        ));
        game.__buildPlayerBlock(builderIdx);
    }

    function test_buildPlayerBlock_failsIfBuilderDoesNotSettleAllBundles() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 ignoredPlayerIdx = uint8((builderIdx + 1) % game.playerCount());
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        game.mint(builderIdx, GOLD_IDX, 1);
        builder.setBid(1);
        builder.ignorePlayer(ignoredPlayerIdx);
        vm.expectRevert(abi.encodeWithSelector(
            Game.BundleNotSettledError.selector,
            builderIdx,
            ignoredPlayerIdx
        ));
        game.__buildPlayerBlock(builderIdx);
    }

    function test_buildPlayerBlock_failsIfBuilderSettlesDifferentBundle() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 replacedPlayerIdx = uint8((builderIdx + 1) % game.playerCount());
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        builder.ignorePlayer(replacedPlayerIdx);
        builder.setBid(1);
        game.mint(builderIdx, GOLD_IDX, 1);
        // Call settleBundle() call for replacedPlayerIdx with the wrong bundle.
        builder.addCallback(IPlayer.buildBlock.selector, address(game), abi.encodeCall(
            Game.settleBundle,
            (replacedPlayerIdx, PlayerBundle(new SwapSell[](1)))
        ));
        vm.expectRevert(abi.encodeWithSelector(
            Game.BundleNotSettledError.selector,
            builderIdx,
            replacedPlayerIdx
        ));
        game.__buildPlayerBlock(builderIdx);
    }

    function test_buildPlayerBlock_failsIfBuilderFails() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        builder.addCallback(
            IPlayer.buildBlock.selector,
            address(this),
            abi.encodeCall(this.revertBack, (bytes('oopsie')))
        );
        vm.expectRevert(abi.encodeWithSelector(
            Game.BuildBlockFailedError.selector,
            builderIdx,
            bytes('oopsie')
        ));
        game.__buildPlayerBlock(builderIdx);
    }

    function test_buildPlayerBlock_builderCanExcludeTheirBundle() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        builder.ignorePlayer(builderIdx);
        game.__buildPlayerBlock(builderIdx);
    }

    function test_buildPlayerBlock_failsIfBuilderDoesntHaveFundsAtTheEndOfBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        builder.setBid(1337);
        // Mint 1336 gold on build.
        builder.addCallback(
            IPlayer.buildBlock.selector,
            address(game),
            abi.encodeCall(TestGame.mint, (builderIdx, GOLD_IDX, 1336))
        );
        vm.expectRevert(abi.encodeWithSelector(
            Game.InsufficientBalanceError.selector,
            builderIdx,
            GOLD_IDX
        ));
        game.__buildPlayerBlock(builderIdx);
    }

    function test_buildPlayerBlock_burnsBid() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        builder.setBid(1337);
        // Mint 1338 gold on build.
        builder.addCallback(
            IPlayer.buildBlock.selector,
            address(game),
            abi.encodeCall(TestGame.mint, (builderIdx, GOLD_IDX, 1338))
        );
        game.__buildPlayerBlock(builderIdx);
        assertEq(game.balanceOf(builderIdx, GOLD_IDX), 1); // 1337 of 1338 is burned.
    }

    function test_buildPlayerBlock_receivesPlayerBundles() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = 0;
        TestPlayer builder = TestPlayer(address(players[builderIdx]));
        PlayerBundle[] memory bundles = new PlayerBundle[](players.length);
        TestPlayer(address(players[1])).setBundle(bundles[1]);
        TestPlayer(address(players[2])).setBundle(bundles[2]);
        vm.expectEmit(true, true, true, true, address(builder));
        emit Building(bundles);
        game.__buildPlayerBlock(builderIdx);
    }

    function test_auctionBlock_returnsHighestBidder() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        for (uint8 i; i < players.length; ++i) {
            game.mint(i, GOLD_IDX, 101);
            TestPlayer(address(players[i])).setBid(100);
        }
        TestPlayer(address(players[builderIdx])).setBid(101);
        (uint8 builderIdx_, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx_, builderIdx);
        assertEq(bid, 101);
    }

    function test_auctionBlock_ignoresRevertingBidder() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        for (uint8 i; i < players.length; ++i) {
            uint256 bid = 100 + i;
            game.mint(i, GOLD_IDX, bid);
            TestPlayer(address(players[i])).setBid(bid);
        }
        TestPlayer(address(players[2])).addCallback(
            IPlayer.buildBlock.selector,
            address(this),
            abi.encodeCall(this.revertBack, ('oops'))
        );
        (uint8 builderIdx_, uint256 bid_) = game.__auctionBlock();
        assertEq(builderIdx_, 1);
        assertEq(bid_, 101);
    }

    function test_auctionBlock_ignoresInsufficientFundsBidder() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        for (uint8 i; i < players.length; ++i) {
            uint256 bid = 100 + i;
            game.mint(i, GOLD_IDX, bid);
            TestPlayer(address(players[i])).setBid(bid);
        }
        game.burn(2, GOLD_IDX, 1);
        (uint8 builderIdx_, uint256 bid_) = game.__auctionBlock();
        assertEq(builderIdx_, 1);
        assertEq(bid_, 101);
    }

    function test_auctionBlock_returnsInvalidPlayerIfNoOneBids() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        (uint8 builderIdx, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx, INVALID_PLAYER_IDX);
        assertEq(bid, 0);
    }

    function test_settleBundle_cannotBeCalledByNonBuilderDuringBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 nonBuilderIdx = uint8((builderIdx + 1) % players.length);
        // Builder will call another player directly who will try to settle a bundle.
        TestPlayer(address(players[builderIdx])).addCallback(
            IPlayer.buildBlock.selector,
            address(players[nonBuilderIdx]),
            abi.encodeCall(CallbackPlayer.poke, ())
        );
        TestPlayer(address(players[nonBuilderIdx])).addCallback(
            CallbackPlayer.poke.selector,
            address(game),
            abi.encodeCall(Game.settleBundle, (0, PlayerBundle(new SwapSell[](0))))
        );
        vm.expectRevert(abi.encodeWithSelector(
            Game.BuildBlockFailedError.selector,
            builderIdx,
            abi.encodeWithSelector(Game.AccessError.selector)
        ));
        game.__buildPlayerBlock(builderIdx);
    }
    
    function test_settleBundle_succeedsIfBundleFails() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 playerIdx = uint8((builderIdx + 1) % players.length);
        PlayerBundle memory bundle = PlayerBundle(new SwapSell[](1));
        bundle.swaps[0] = SwapSell({
            fromAssetIdx: 0,
            toAssetIdx: 1,
            fromAmount: 1e18
        });
        game.setCurrentBuilder(builderIdx);
        vm.expectEmit(true, true, true, true);
        emit Game.BundleSettled(playerIdx, false, bundle);
        vm.prank(address(players[builderIdx]));
        game.settleBundle(playerIdx, bundle);
    }
    
    function test_settleBundle_failsIfNotEnoughGas() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 playerIdx = uint8((builderIdx + 1) % players.length);
        PlayerBundle memory bundle = PlayerBundle(new SwapSell[](1));
        bundle.swaps[0] = SwapSell({
            fromAssetIdx: 0,
            toAssetIdx: 1,
            fromAmount: 1e18
        });
        game.setCurrentBuilder(builderIdx);
        vm.expectRevert(abi.encodeWithSelector(Game.InsufficientBundleGasError.selector));
        vm.prank(address(players[builderIdx]));
        game.settleBundle{gas: MIN_GAS_PER_BUNDLE_SWAP * bundle.swaps.length + 2e3}(playerIdx, bundle);
    }

    function test_settleBundle_failsIfSameBundleAlreadySettled() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 playerIdx = uint8((builderIdx + 1) % players.length);
        PlayerBundle memory bundle = PlayerBundle(new SwapSell[](1));
        bundle.swaps[0] = SwapSell({
            fromAssetIdx: 0,
            toAssetIdx: 1,
            fromAmount: 1e18
        });
        game.setCurrentBuilder(builderIdx);
        vm.expectEmit(true, true, true, true);
        emit Game.BundleSettled(playerIdx, false, bundle);
        vm.prank(address(players[builderIdx]));
        game.settleBundle(playerIdx, bundle);
        vm.expectRevert(abi.encodeWithSelector(
            Game.BundleAlreadySettledError.selector,
            playerIdx
        ));
        vm.prank(address(players[builderIdx]));
        game.settleBundle(playerIdx, bundle);
    }

    function test_settleBundle_failsIfDifferentBundleButSamePlayerAlreadySettled() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 playerIdx = uint8((builderIdx + 1) % players.length);
        PlayerBundle memory bundle = PlayerBundle(new SwapSell[](1));
        bundle.swaps[0] = SwapSell({
            fromAssetIdx: 0,
            toAssetIdx: 1,
            fromAmount: 1e18
        });
        game.setCurrentBuilder(builderIdx);
        vm.expectEmit(true, true, true, true);
        emit Game.BundleSettled(playerIdx, false, bundle);
        vm.prank(address(players[builderIdx]));
        game.settleBundle(playerIdx, bundle);
        vm.expectRevert(abi.encodeWithSelector(
            Game.BundleAlreadySettledError.selector,
            playerIdx
        ));
        vm.prank(address(players[builderIdx]));
        game.settleBundle(playerIdx, bundle);
    }

    function test_settleBundle_canSwap() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 playerIdx = uint8((builderIdx + 1) % players.length);
        game.mint(playerIdx, GOLD_IDX, 1e18);
        PlayerBundle memory bundle = PlayerBundle(new SwapSell[](1));
        bundle.swaps[0] = SwapSell({
            fromAssetIdx: 0,
            toAssetIdx: 1,
            fromAmount: 1e18
        });
        game.mint(playerIdx, 0, 1e18);
        game.setCurrentBuilder(builderIdx);
        uint256 toAmount = game.quoteSell(0, 1, 1e18);
        vm.expectEmit(true, true, true, true);
        emit Game.Swap(playerIdx, 0, 1, 1e18, toAmount);
        vm.expectEmit(true, true, true, true);
        emit Game.BundleSettled(playerIdx, true, bundle);
        vm.prank(address(players[builderIdx]));
        game.settleBundle(playerIdx, bundle);
    }

    function test_sameStateForPlayersDuringBlockAuctionAndBuilding() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(StateTrackingPlayer).creationCode,
            type(StateTrackingPlayer).creationCode
        ]));
        uint8 playerIdx = 0;
        uint8 builderIdx = 1;
        StateTrackingPlayer player = StateTrackingPlayer(address(players[playerIdx]));
        StateTrackingPlayer builder = StateTrackingPlayer(address(players[builderIdx]));
        bytes32 playerCreateBundleStateHash;
        bytes32 builderBuildBlockStateHash;
        
        vm.recordLogs();
        game.__auctionBlock();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            bytes32 sig = log.topics[0];
            if (log.emitter == address(player) && sig == CREATE_BUNDLE_STATE_EVENT_SIGNATURE) {
                (uint8 playerIdx_, uint8 builderIdx_, bytes32 h) =
                    abi.decode(log.data, (uint8, uint8, bytes32));
                if (playerIdx_ == playerIdx && builderIdx_ == builderIdx) {
                    playerCreateBundleStateHash = h;
                }
            } else if (log.emitter == address(builder) && sig == BUILD_BLOCK_STATE_EVENT_SIGNATURE) {
                (uint8 builderIdx_, bytes32 h) =
                    abi.decode(log.data, (uint8, bytes32));
                assertEq(builderIdx_, builderIdx, 'buildBlock() builderIdx');
                builderBuildBlockStateHash = h;
            }
        }
        assertTrue(playerCreateBundleStateHash != 0, 'playerCreateBundleStateHash != 0');
        assertTrue(builderBuildBlockStateHash != 0, 'builderBuildBlockStateHash != 0');

        vm.expectEmit(true, true, true, true, address(player));
        emit StateTrackingPlayer.CreateBundleState(playerIdx, builderIdx, playerCreateBundleStateHash);
        vm.expectEmit(true, true, true, true, address(builder));
        emit StateTrackingPlayer.BuildBlockState(builderIdx, builderBuildBlockStateHash);
        game.__buildPlayerBlock(builderIdx);
    }

    function test_quoteBuy_revertsWithInvalidAsset() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        game.quoteBuy(fromAsset, assetCount, 1);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        game.quoteBuy(assetCount, toAsset, 1);
    }

    function test_quoteSell_revertsWithInvalidAsset() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        game.quoteSell(fromAsset, assetCount, 1);
        vm.expectRevert(AssetMarket.InvalidAssetError.selector);
        game.quoteSell(assetCount, toAsset, 1);
    }

    function test_quoteBuy_cannotBuyEntireReserve() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        uint256[] memory reserves = game.marketState();
        uint256 buyAmount = reserves[toAsset];
        vm.expectRevert(AssetMarket.InsufficientLiquidityError.selector);
        game.quoteBuy(fromAsset, toAsset, buyAmount);
    }

    function test_quoteBuy_canQuote() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        uint256[] memory reserves = game.marketState();
        uint256 buyAmount = reserves[toAsset] / 2;
        uint256 sellAmount = game.quoteBuy(fromAsset, toAsset, buyAmount);
        assertGe(sellAmount, reserves[fromAsset] * buyAmount / reserves[toAsset]);
    }

    function test_quoteSell_canQuote() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        uint8 fromAsset = uint8((assetCount + T.randomUint256()) % assetCount);
        uint8 toAsset = uint8((fromAsset + 1) % assetCount);
        uint256[] memory reserves = game.marketState();
        uint256 sellAmount = reserves[fromAsset] / 2;
        uint256 buyAmount = game.quoteSell(fromAsset, toAsset, sellAmount);
        assertLe(buyAmount, reserves[toAsset] * sellAmount / reserves[fromAsset]);
    }

    function test_buy_cannotBeCalledByNonBuilder() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 nonBuilderIdx = uint8((builderIdx + 1) % players.length);
        game.setCurrentBuilder(builderIdx);
        vm.expectRevert(abi.encodeWithSelector(Game.AccessError.selector));
        vm.prank(address(players[nonBuilderIdx]));
        game.buy(0, 1, 0);
    }

    function test_sell_cannotBeCalledByNonBuilder() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        uint8 nonBuilderIdx = uint8((builderIdx + 1) % players.length);
        game.setCurrentBuilder(builderIdx);
        vm.expectRevert(abi.encodeWithSelector(Game.AccessError.selector));
        vm.prank(address(players[nonBuilderIdx]));
        game.sell(0, 1, 0);
    }

    function test_buy_performsSwap() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        game.setCurrentBuilder(builderIdx);
        game.mint(builderIdx, GOLD_IDX, 1e18);
        uint256 toAmount = 1e17;
        uint256 fromAmount = game.quoteBuy(GOLD_IDX, GOLD_IDX + 1, toAmount);
        assertGt(fromAmount, 0);
        vm.expectEmit(true, true, true, true);
        emit Game.Burn(builderIdx, GOLD_IDX, fromAmount);
        vm.expectEmit(true, true, true, true);
        emit Game.Mint(builderIdx, GOLD_IDX + 1, toAmount);
        vm.expectEmit(true, true, true, true);
        emit Game.Swap(builderIdx, GOLD_IDX, GOLD_IDX + 1, fromAmount, toAmount);
        vm.prank(address(players[builderIdx]));
        game.buy(GOLD_IDX, GOLD_IDX + 1, toAmount);
        assertEq(game.balanceOf(builderIdx, GOLD_IDX), 1e18 - fromAmount);
        assertEq(game.balanceOf(builderIdx, GOLD_IDX + 1), toAmount);
    }

    function test_sell_performsSwap() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        game.setCurrentBuilder(builderIdx);
        game.mint(builderIdx, GOLD_IDX, 1e18);
        uint256 fromAmount = 1e17;
        uint256 toAmount = game.quoteSell(GOLD_IDX, GOLD_IDX + 1, fromAmount);
        assertGt(toAmount, 0);
        vm.expectEmit(true, true, true, true);
        emit Game.Burn(builderIdx, GOLD_IDX, fromAmount);
        vm.expectEmit(true, true, true, true);
        emit Game.Mint(builderIdx, GOLD_IDX + 1, toAmount);
        vm.expectEmit(true, true, true, true);
        emit Game.Swap(builderIdx, GOLD_IDX, GOLD_IDX + 1, fromAmount, toAmount);
        vm.prank(address(players[builderIdx]));
        game.sell(GOLD_IDX, GOLD_IDX + 1, fromAmount);
        assertEq(game.balanceOf(builderIdx, GOLD_IDX), 1e18 - fromAmount);
        assertEq(game.balanceOf(builderIdx, GOLD_IDX + 1), toAmount);
    }

    function test_buy_failsIfSellingMoreThanBalance() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        game.setCurrentBuilder(builderIdx);
        game.mint(builderIdx, GOLD_IDX, 1);
        uint256 toAmount = 1e17;
        uint256 fromAmount = game.quoteBuy(GOLD_IDX, GOLD_IDX + 1, toAmount);
        assertGt(fromAmount, game.balanceOf(builderIdx, GOLD_IDX));
        vm.expectRevert(abi.encodeWithSelector(
            Game.InsufficientBalanceError.selector,
            builderIdx,
            GOLD_IDX
        ));
        vm.prank(address(players[builderIdx]));
        game.buy(GOLD_IDX, GOLD_IDX + 1, toAmount);
    }

    function test_sell_failsIfSellingMoreThanBalance() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode,
            type(TestPlayer).creationCode
        ]));
        uint8 builderIdx = _getRandomPlayerIdx(game);
        game.setCurrentBuilder(builderIdx);
        game.mint(builderIdx, GOLD_IDX, 1);
        uint256 fromAmount = 2;
        vm.expectRevert(abi.encodeWithSelector(
            Game.InsufficientBalanceError.selector,
            builderIdx,
            GOLD_IDX
        ));
        vm.prank(address(players[builderIdx]));
        game.sell(GOLD_IDX, GOLD_IDX + 1, fromAmount);
    }

    function _createGame(bytes[] memory playerCreationCodes)
        private returns (TestGame game, IPlayer[] memory players)
    {
        uint256[] memory salts;
        (salts, players) = _minePlayers(Game(_getNextDeployAddress()), playerCreationCodes);
        game = new TestGame(sc2, playerCreationCodes, salts);
    }

    function _minePlayers(Game game, bytes[] memory playerCreationCodes)
        private view returns (uint256[] memory salts, IPlayer[] memory players)
    {
        address[] memory addrs;
        (salts, addrs) = LibMatchUtils.minePlayerSaltsAndAddresses(
            address(game),
            address(sc2),
            bytes32(uint256(1337)),
            playerCreationCodes
        );
        assembly ("memory-safe") { players := addrs }
    }

    function _getNextDeployAddress() internal view returns (address) {
        return LibMatchUtils.getCreateAddress(
            address(this),
            uint32(vm.getNonce(address(this)))
        );
    }

    function _getMaxAssetBalance(Game game, uint8 playerIdx)
        internal view returns (uint8 maxAssetIdx, uint256 maxAssetBal)
    {
        uint8 assetCount = game.assetCount();
        for (uint8 i; i < assetCount; ++i) {
            uint256 bal = game.balanceOf(playerIdx, i);
            if (bal > maxAssetBal) {
                maxAssetIdx = i;
                maxAssetBal = bal;
            }
        }
    }

    function _getMaxNonGoldAssetBalance(Game game, uint8 playerIdx)
        internal view returns (uint8 maxAssetIdx, uint256 maxAssetBal)
    {
        maxAssetIdx = GOLD_IDX + 1;
        uint8 assetCount = game.assetCount();
        for (uint8 i = GOLD_IDX + 1; i < assetCount; ++i) {
            uint256 bal = game.balanceOf(playerIdx, i);
            if (bal > maxAssetBal) {
                maxAssetIdx = i;
                maxAssetBal = bal;
            }
        }
    }

    function _getRandomNonGoldAssetIdx(Game game) private view returns (uint8) {
        return uint8(1 + T.randomUint256() % (game.assetCount() - 1));
    }

    function _getRandomPlayerIdx(Game game) private view returns (uint8) {
        return uint8(T.randomUint256() % game.playerCount());
    }
}

contract TestGame is Game {
    uint8 public mockWinnerIdx = MOCK_UNSET_PLAYER_IDX;
    uint8 public mockBuilderIdx = MOCK_UNSET_PLAYER_IDX; 
    uint256 public mockBuilderBid;

    constructor(SafeCreate2 sc2, bytes[] memory playerCreationCodes, uint256[] memory deploySalts)
        Game(msg.sender, sc2, playerCreationCodes, deploySalts)
    {}

    function mint(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) external {
        _assertValidPlayerIdx(playerIdx);
        _mint(playerIdx, assetIdx, assetAmount);
    }

    function burn(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) external {
        _assertValidPlayerIdx(playerIdx);
        _burn(playerIdx, assetIdx, assetAmount);
    }

    function setRound(uint16 r) external {
        _round = r;
    }

    function setMockWinner(uint8 winnerIdx) external {
        _assertValidPlayerIdx(winnerIdx);
        mockWinnerIdx = winnerIdx;
    }

    function setMockBlockAuctionWinner(uint8 builderIdx, uint256 bid) external {
        _assertValidPlayerIdx(builderIdx);
        mockBuilderIdx = builderIdx;
        mockBuilderBid = bid;
    }

    function setCurrentBuilder(uint8 builderIdx) external {
        _assertValidPlayerIdx(builderIdx);
        IPlayer builder =
            builderIdx == INVALID_PLAYER_IDX || builderIdx == MOCK_UNSET_PLAYER_IDX
            ? NULL_PLAYER
            : _playerByIdx[builderIdx];
        t_currentBuilder.store(address(builder));
    }

    function __distributeIncome() external virtual {
        _distributeIncome();
    }

    function __buildPlayerBlock(uint8 builderIdx) external returns (uint256 bid) {
        _assertValidPlayerIdx(builderIdx);
        return _buildPlayerBlock(builderIdx);
    }

    function __buildBlock() external {
        return _buildBlock();
    }

    function __auctionBlock()
        external returns (uint8 builderIdx, uint256 builderBid)
    {
        return _auctionBlock();
    }

    function _auctionBlock()
        internal override returns (uint8 builderIdx, uint256 builderBid)
    {
        if (mockBuilderIdx != MOCK_UNSET_PLAYER_IDX) {
            return (mockBuilderIdx, mockBuilderBid);
        }
        return Game._auctionBlock();
    }

    function _findWinner(uint16 round_)
        internal override view returns (IPlayer winner)
    {
        if (mockWinnerIdx != MOCK_UNSET_PLAYER_IDX) {
            return mockWinnerIdx == INVALID_PLAYER_IDX
                ? NULL_PLAYER
                : _playerByIdx[mockWinnerIdx];
        }
        return Game._findWinner(round_);
    }

    function _assertValidPlayerIdx(uint8 playerIdx) private view {
        assert(
            playerIdx == INVALID_PLAYER_IDX
            || playerIdx == MOCK_UNSET_PLAYER_IDX
            || playerCount > playerIdx
        );
    }
}

contract NoopPlayer is IPlayer {
    uint8 public immutable PLAYER_IDX;
    uint8 immutable PLAYER_COUNT;
    uint8 immutable ASSET_COUNT;

    constructor(Game, uint8 playerIdx, uint8 playerCount, uint8 assetCount) {
        PLAYER_IDX = playerIdx;
        PLAYER_COUNT = playerCount;
        ASSET_COUNT = assetCount;
        emit PlayerCreated(address(this), playerIdx, playerCount);
    }

    function createBundle(uint8 builderIdx)
        public virtual returns (PlayerBundle memory bundle)
    {
        emit Bundling(builderIdx);
        return bundle;
    }

    function buildBlock(PlayerBundle[] calldata bundles)
        public virtual returns (uint256 bid)
    {
        emit Building(bundles);
        return 0;
    }
}

contract CallbackPlayer is NoopPlayer {
    struct Call {
        address target;
        bytes data;
    }

    event Called(
        bytes4 playerFnSelector,
        address target,
        bytes data,
        bytes resultData
    );

    mapping (bytes4 playerFnSelector => Call[]) _calls;
    
    constructor(Game game, uint8 playerIdx, uint8 playerCount, uint8 assetCount)
        NoopPlayer(game, playerIdx, playerCount, assetCount) {}
    
    function addCallback(bytes4 playerFnSelector, address target, bytes calldata data) external {
        _calls[playerFnSelector].push(Call(target, data));
    }
    
    function createBundle(uint8 builderIdx)
        public override virtual returns (PlayerBundle memory bundle)
    {
        super.createBundle(builderIdx);
        _doCalls();
        return bundle;
    }

    function buildBlock(PlayerBundle[] calldata bundles)
        public override virtual returns (uint256 bid)
    {
        super.buildBlock(bundles);
        _doCalls();
        return 0;
    }

    function poke() external {
        _doCalls();
    }

    function _doCalls() private {
        Call[] storage calls = _calls[msg.sig];
        uint256 n = calls.length;
        for (uint256 i; i < n; ++i) {
            Call memory call_ = calls[i];
            (bool success, bytes memory resultData) = call_.target.call(call_.data);
            if (!success) {
                resultData.rawRevert();
            }
            emit Called(msg.sig, call_.target, call_.data, resultData);
        }
    }
}

contract StateTrackingPlayer is NoopPlayer {
    event CreateBundleState(uint8 playerIdx, uint8 builderIdx, bytes32 h);
    event BuildBlockState(uint8 builderIdx, bytes32 h);

    constructor(Game game, uint8 playerIdx, uint8 playerCount, uint8 assetCount)
        NoopPlayer(game, playerIdx, playerCount, assetCount) {}

    function createBundle(uint8 builderIdx)
        public override returns (PlayerBundle memory bundle)
    {
        super.createBundle(builderIdx);
        emit CreateBundleState(PLAYER_IDX, builderIdx, _getStateHash());
        return bundle;
    }

    function buildBlock(PlayerBundle[] calldata bundles)
        public override returns (uint256)
    {
        super.buildBlock(bundles);
        emit BuildBlockState(PLAYER_IDX, _getStateHash());
        TestGame game = TestGame(msg.sender);
        for (uint8 i; i < bundles.length; ++i) {
            game.settleBundle(i, bundles[i]);
        }
        return 0;
    }

    function _getStateHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                msg.data,
                msg.sender,
                msg.value,
                gasleft(),
                address(this).balance,
                isAddressCold(address(bytes20(keccak256(abi.encode(address(this), msg.data)))))
            )
        );
    }
}

contract TestPlayer is CallbackPlayer {
    struct AssetOwed {
        IPlayer player;
        uint8 assetIdx;
        uint256 amount;
    }

    uint8 public ignoredPlayerIdx = INVALID_PLAYER_IDX;
    uint256 public bid;
    PlayerBundle _bundle;

    constructor(Game game, uint8 playerIdx, uint8 playerCount, uint8 assetCount)
        CallbackPlayer(game, playerIdx, playerCount, assetCount) {}

    function createBundle(uint8 builderIdx)
        public override returns (PlayerBundle memory bundle)
    {
        super.createBundle(builderIdx);
        return _bundle;
    }

    function buildBlock(PlayerBundle[] calldata bundles)
        public override returns (uint256 bid_)
    {
        super.buildBlock(bundles);
        TestGame game = TestGame(msg.sender);
        for (uint8 i; i < bundles.length; ++i) {
            if (ignoredPlayerIdx == i) continue;
            game.settleBundle(i, bundles[i]);
        }
        return bid;
    }

    function setBundle(PlayerBundle memory bundle) external {
        delete _bundle.swaps;
        for (uint256 i; i < bundle.swaps.length; ++i) {
            _bundle.swaps.push(bundle.swaps[i]);
        }
    }
   
    function setBid(uint256 bid_) external {
        bid = bid_;
    }

    function ignorePlayer(uint8 playerIdx) external {
        ignoredPlayerIdx = playerIdx;
    }
}

contract EmptyContract {}