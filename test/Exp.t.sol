// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

abstract contract GameComponent {
    IGame public immutable GAME;

    constructor(IGame game) { GAME = game; }

    modifier onlyOwnerOrGameComponent(address owner) {
        if (msg.sender != owner) {
            if (!GAME.isGameComponent(msg.sender)) {
                revert CallerNotAllowed(msg.sender);
            }
        }
        _;
    }

    modifier onlyGameComponent() {
        if (!GAME.isGameComponent(msg.sender)) {
            revert CallerNotAllowed(msg.sender);
        }
        _;
    }

    function _burnRandomGas(uint256 min, uint256 max) internal {
        assert(max >= min);
        unchecked {
            uint256 g = min + (_randomUint256() % (max - min));
            try this.crash{gas: g}() {
                assert(false);
            } catch {}
        }
    }

    function crash() external pure {
        assembly ("memory-safe") {
            invalid();
        }
    }

    function _randomUint256() internal view returns (uint256 r) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, or(shl(128, msize()), gas()))
            p := add(p, 0x20)
            mstore(p, origin())
            p := add(p, 0x20)
            mstore(p, codehash())
            p := add(p, 0x20)
            calldatacopy(p, 0, calldatasize())
            p := add(p, calldatasize())
            r := keccak256(mload(0x40), sub(p, mload(0x40)))
        }
    }
}

interface IToken {
    function name() external view returns (string memory);
    function balanceOf(address owner) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external;
}

abstract contract GameConstants {
    uint256 constant RAISE_ARG0 = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
}

// Gold needs to be a token too for hooks.
contract Token is IToken, GameConstants {
    error InsufficientBalanceError(address from, address to, uint256 overdraft);
    
    string public name;
    mapping (address => uint256) public balanceOf;
   
    constructor(string memory name_) { name = name_; }
   
    function transferFrom(address from, address to, uint256 amount)
        external
        onlyOwnerOrGameComponent(from)
    {
        GAME.raise(abi.encodeCall(IGameHooks.onBeforeTransfer, (RAISE_ARG0, this, from, to, amount)));
        unchecked {
            uint256 fromBal = balanceOf[from];
            // From address(0) is a mint.
            if (from != address(0)) {
                if (fromBal < amount) {
                    revert InsufficientBalanceError(from, to, amount - fromBal);
                }
                balanceOf[from] = fromBal - amount;
            }
            // To address(0) is a burn.
            if (to != address(0)) {
                balanceOf[to] += amount;
            }
        }
        GAME.raise(abi.encodeCall(IGameHooks.onAfterTransfer, (RAISE_ARG0, this, from, to, amount)));
    }
}

interface IGameHooks {
    function onBeforeBorrow(address caller, IToken, uint256 borrowAmount, uint256 fee, bytes hookData) external view returns (bytes memory nextHookData);
    function onAfterBorrow(address caller, IToken, uint256 borrowAmount, uint256 fee, bytes hookData) external view returns (bytes memory nextHookData);
    function onBeforeDeposit(address caller, IToken, uint256 depositAmount, uint256 yield, bytes hookData) external view returns (bytes memory nextHookData);
    function onAfterDeposit(address caller, IToken, uint256 depositAmount, uint256 yield, bytes hookData) external view returns (bytes memory nextHookData);
    function onBeforeWithdraw(address caller, IToken, uint256 withdrawAmount, uint256 yield, bytes hookData) external view returns (bytes memory nextHookData);
    function onAfterWithdraw(address caller, IToken, uint256 withdrawAmount, uint256 yield, bytes hookData) external view returns (bytes memory nextHookData);
    function onBeforeSell(address caller, IToken, uint256 productAmount, uint256 ethAmount, bytes hookData) external view returns (bytes memory nextHookData);
    function onAfterSell(address caller, IToken, uint256 productAmount, uint256 ethAmount, bytes hookData) external view returns (bytes memory nextHookData);
    function onBeforeBuy(address caller, IToken, uint256 ethAmount, uint256 productAmount, bytes hookData) external view returns (bytes memory nextHookData);
    function onAfterBuy(address caller, IToken, uint256 ethAmount, uint256 productAmount, bytes hookData) external view returns (bytes memory nextHookData);
    function onBeforeTransfer(IToken, address from, address to, uint256 amount, bytes hookData) external view returns (bytes memory nextHookData);
    function onAfterTransfer(IToken, address from, address to, uint256 amount, bytes hookData) external view returns (bytes memory nextHookData);
}

interface IGame {
    function isGameComponent() external view returns (bool);
    function raise(bytes calldata hookCallData) external;
}

contract Game is IGame, GameComponent(this) {

    // 10 markets <- (n! / (r!(n - r)!))
    enum Currencies {
        Gold,
        Fruits,
        Pies,
        Fish,
        Rugs
    }

    uint256 constant STARTING_FUNDS = 1 ether;
    uint256 constant INCOME_RATIO = 0.6180339887498948e18;

    uint256 public roundsPlayed;
    IPlayer[] _players;
    
    constructor(bytes[] memory playerInitCodes) {
        uint256 salt = _randomUint256();
        for (uint256 i; i < playerInitCodes.length; ++i) {
            bytes memory ic = playerInitCodes[i];
            IPlayer player;
            assembly { player := create2(0, add(0x20, ic), mload(ic), add(salt, i)) }
            _players.push(player);
        }
    }

    function raise(bytes calldata hookCallData) external onlyGameComponent {
        bytes memory patchedHookCallData;
        if (address(sheriff) != address(0)) {
            bytes memory hookData = _hookData;
            uint256 hookDataLength = hookData.length;
            unchecked {
                patchedHookCallData = new bytes(hookCallData.length + hookDataLength);
                assembly ("memory-safe") {
                    mstore(patchedHookCallData, hookCallData.length)
                    calldatacopy(add(patchedHookCallData, 0x20), hookCallData.offset, hookCallData.length)
                    mstore(add(patchedHookCallData, 0x20), hookCallData.length)
                    staticcall(gas(), 0x40, add(hookData, 0x20), hookDataLength, 0x00, 0x00)
                    returndatacopy(add(patchedHookCallData, add(hookCallData.length, 0x20)), hookDataLength)
                }
            } 
            (bool s, bytes memory r) = address(sheriff).staticcall(patchedHookCallData);
            if (!s) {
                assembly { revert(add(r, 0x20), mload(r)) }
            }
            _hookData = abi.decode(r, (bytes));
        } else {
            unchecked {
                _burnRandomGas(100, 8e6);
            }
        }
    }

    function startGame() external payable onlyOrigin {
        require(roundsPlayed == 0);
        require(msg.value == numPlayers * STARTING_FUNDS);
        IPlayer[] memory players_ = _players;
        IToken[] memory products = _products;
        for (uint256 i; i < players_.length; ++i) {
            _fundPlayer(players_[i], products, STARTING_FUNDS);
        }
    }

    function _fundPlayer(address payable player, IToken[] products, uint256 amount) private {
        player.transfer(amount);
        for (uint256 i; i < products.length; ++i) {
            products[i].mint(player, amount);
        }
    }

    function endGame() external onlyOrigin {
        // Player with most $ wins...
    }

    function playRound() external payable onlyOrigin {
        uint256 numPlayers = _players.length;
        require(msg.value == numPlayers * ROUND_FUNDS);
        // Rotate the current sheriff. Everyone else is a merchant.
        uint256 currentSheriffIdx = roundsPlayed++ % _players.length;
        IPlayer[] memory players_ = _players;
        IToken memory products_ = products;
        // Grant each merchant one of each product and some ETH (if provided).
        for (uint256 i = 1; i < numPlayers; ++i) {
            IMerchant merchant = players_[(currentSheriffIdx + i) % numPlayers];
            _fundPlayer(merchant, produts_, ROUND_FUNDS);
        }
        // Each merchant takes their turn.
        for (uint256 i = 1; i < numPlayers; ++i) {
            players_[(currentSheriffIdx + i) % numPlayers].operate(activity_, products_, players_, currentSheriffIdx);
        }
        // Sheriff takes their turn last.
        players_[currentSheriffIdx].process(activity_, products_, players_, currentSheriffIdx);
    }
}


interface IGame {
    function raise(bytes calldata hookCallData) external;
}

contract Game {
    function simulate(uint256 opIdx, bytes memory hookData) external returns (bytes memory finalHookData) {
        for (uint256)

    }
}

interface IMarket {
    function rates(IToken) external view returns (uint256 depositRate, uint256 borrowRate);
    function sell(IToken, productAmount) external returns (uint256 ethAmount);
    function buy(IToken, ethAmount) external returns (uint256 productAmount);
    function borrow(IToken, borrowAmount, callbackSelector) external returns (uint256 fee);
    function deposit(IToken, depositAmount) external returns (uint256 yield);
    function withdraw(IToken, withdrawAmount) external returns (uint256 yield);
}

interface IToken {
    function name() external view returns (string memory);
    function balanceOf(owner) external view returns (uint256);
}

interface IMerchant is IBuyer, ISeller {
    function operate(IBlock, IMarket, IProducts[], IPlayer[], uint256 currentSheriffIdx) external;
}

interface ISheriff {
    function process(block_) external;
    function onBeforeExecute(bytes memory data) external;
    function onAfterExecute(bytes memory data) external returns (bytes memory result);
}

interface IBlock {
    // Submit an operation. If a merchant calls this more than once, it overwrites the previous one.
    // Stores them sorted by descending bribe.
    function submit(bytes callData, uint256 gasLimit) external payable returns (uint256 opIdx);
    // Gets the number of submitted operations. Only callable by the sheriff.
    function length() external view returns (uint256);
    // Simulate executing an operation, with all hooks enabled.
    // The sheriff can use the market interactively.
    // Return value is the result of `onAfterExecute()`.
    function simulate(uint256 opIdx, bytes hookData) external returns (bytes memory result);
    // Actually execute an operation. Only execute hooks will be enabled.
    // The sheriff can use the market interactively.
    // Return value is the result of `onAfterExecute()`.
    function execute(uint256 opIdx, bytes hookData) external returns (bytes memory result);
}

struct QueuedOperation {
    address merchant;
    bytes callData;
}

contract ExpTest is Test {
    function setUp() external {
    }

    function testFoo() external {
    }
}
