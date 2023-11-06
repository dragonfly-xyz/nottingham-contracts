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
    Fish
}

contract Market {
    modifier whileActing() {
        require(GAME.isActing);
        _;
    }

    function balanceOf(Asset asset, address) external view returns (uint256);
    function quote(Asset sellAsset, Asset buyAsset, uint256 sellAmount) external view returns (uint256 buyAmount);
    function transfer(Asset asset, address to, uint256 amount) external whileActing;
    function swap(Asset sellAsset, Asset buyAsset, uint256 sellAmount) external whileActing returns (uint256 buyAmount);
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

contract Game {
    uint256 _gasUsedByAllPlayers;
    mapping (address => uint256) _gasUsedByPlayer;
    address public isActing;
    uint256 public round; 
    address _currentBuilder;
    address[] players;

    modifier onlyCurrentBuilder() {
        require(msg.sender == _currentBuilder);
        _;
    }

    modifier notActing() {
        require(!isActing);
        _;
    }
    

    function playRound() external onlyGameMaster {
        uint256 maxBid;
        uint256 bidWinner;
        for (uint256 i = 0; i < players.length; ++i) {
            address player = players[i];
            uint256 bid;
            _currentBuilder = player;
            try this.__buildAndRevert(player) {
                assert(false);
            } catch (bytes memory err) {
                if (err.length == 32)  {
                    bid = abi.decode(err, (uint256))
                }
            }
            if (bid > maxBid)  {
                maxBid = bid; 
                bidWinner = player;
            }
        }
        bool blockBuilt;
        if (bidWinner) {
            _currentBuilder = bidWinner;
            try Builder(player).build{gas: MAX_BUILD_GAS}(players) {
                built = true;
            } catch {}
        }
        if (!blockBuilt) {
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
        bytes memory callData = abi.encodeCall(build, (players));
        assembly ("memory-safe")  {
            let s := call(MAX_BUILD_GAS, builder, 0, add(callData, 0x20), mload(callData), 0, 0x20)
            if s {
               revert(0, 0x20) 
            }
            revert(0, 0)
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
            bool include;
            (include, result) = Builder(builder).afterInclude(player, data);
            if (!include) {
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
        onlySelf
    {
        require(!isActing);
        isActing = true;
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
        isActing = false; 
    }
}