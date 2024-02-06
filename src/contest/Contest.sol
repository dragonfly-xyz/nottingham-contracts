// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

struct Confirmation {
    uint256 expiry;
    uint256 nonce;
    bytes32 r;
    bytes32 s;
    uint8 v;
}

struct SeasonInfo {
    bytes32 pubKey;
    bytes32 privKey;
    address winner;
    uint96 unclaimedPrize;
    uint32 playerCodeCount;
    mapping (address player => bytes32 codeHash) playerCodeHashes;
}
    
library LibContest {
    bytes32 constant private REGISTRATION_PREFIX = keccak256(unicode"ᴙɘgiꙅTᴙATioᴎ");

    function hashRegistration(
        address contest,
        uint256 chainId,
        address registrant,
        Confirmation memory confirmation
    )
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(
            REGISTRATION_PREFIX,
            contest,
            chainId,
            registrant,
            confirmation.expiry,
            confirmation.nonce
        ));
    }
}

contract Contest {
    error AccessError();
    error ConfirmationConsumedError();
    error InvalidConfirmationError();
    error NotRegisteredError();
    error NotSeasonError();
    error SeasonClosedError();
    error SeasonNotClosedError();
    error InvalidKeyError();
    error NotWinnerError();
    error AlreadyClaimedError();

    event Registered(address indexed player);
    event Retired(address indexed player);
    event SeasonClosed(uint32 indexed season, bytes32 privateKey);
    event WinnerDeclared(uint32 indexed season, address indexed winner, uint256 prize);
    event SeasonStarted(uint32 indexed season, bytes32 publicKey);
    event PrizeClaimed(uint32 indexed season, address indexed winner, uint256 prize);
    event CodeCommitted(uint32 indexed season, address indexed player, bytes encryptedCode);

    address public immutable HOST;
    address public immutable ADMIN;
    address public immutable REGISTRAR;

    uint32 public playerCount;
    uint32 public currentSeasonIdx;
    uint96 public unclaimedPrize;
    mapping (uint32 seasonIdx => SeasonInfo info) private _seasons;
    mapping (address player => uint256 block) public playerRegisteredBlock;
    mapping (bytes32 confirmationHash => uint256 block) public confirmationConsumedBlock;

    constructor(address payable host, address retirer, address notary) {
        HOST = host;
        REGISTRAR = notary;
        ADMIN = retirer;
    }

    modifier onlyFrom(address from) {
        if (msg.sender != from) revert AccessError();
        _;
    }

    modifier onlyRegisteredPlayer() {
        if (playerRegisteredBlock[msg.sender] == 0) revert NotRegisteredError();
        _;
    }

    modifier duringSameSeason(uint32 seasonIdx) {
        if (seasonIdx != currentSeasonIdx) revert NotSeasonError();
        _;
    }
    
    function retire(address payable player) external onlyFrom(ADMIN) {
        if (playerRegisteredBlock[player] != 0) {
            playerRegisteredBlock[player] = block.number;
            --playerCount;
            emit Retired(player);
        }
    }

    function register(Confirmation memory confirmation) external {
        if (playerRegisteredBlock[msg.sender] == 0) {
            _consumeConfirmation(msg.sender, confirmation);
            playerRegisteredBlock[msg.sender] = block.number;
            ++playerCount;
            emit Registered(msg.sender);
        }
    }

    function isSeasonClosed() external view returns (bool) {
        return _isSeasonClosed(_seasons[currentSeasonIdx]);
    }

    function setPlayerCode(uint32 seasonIdx, bytes memory encryptedCode)
        external
        onlyRegisteredPlayer
        duringSameSeason(seasonIdx)
    {
        SeasonInfo storage season = _seasons[seasonIdx];
        if (_isSeasonClosed(season)) revert SeasonClosedError();
        if (season.playerCodeHashes[msg.sender] == 0) ++season.playerCodeCount;
        season.playerCodeHashes[msg.sender] = keccak256(encryptedCode);
        emit CodeCommitted(seasonIdx, msg.sender, encryptedCode);
    }

    function getPlayerCodeHash(uint32 seasonIdx, address player)
        external view returns (bytes32 codeHash)
    {
        if (playerRegisteredBlock[player] == 0) {
            return 0;
        }
        return _seasons[seasonIdx].playerCodeHashes[player];
    }

    function getWinner(uint32 seasonIdx)
        external view returns (address winner, uint96 unclaimedPrize_)
    {
        SeasonInfo storage season = _seasons[seasonIdx];
        return (season.winner, season.unclaimedPrize);
    }

    function newSeason(
        uint32 prevSeasonIdx,
        bytes32 seasonPubKey,
        address prevWinner
    )
        external
        payable
        duringSameSeason(prevSeasonIdx)
        onlyFrom(HOST)
    {
        if (seasonPubKey == 0) revert InvalidKeyError();
        SeasonInfo storage prevSeason = _seasons[prevSeasonIdx];
        if (!_isSeasonClosed(prevSeason)) revert SeasonNotClosedError();
        if (prevWinner != address(0)) {
            uint96 unclaimedPrize_ = unclaimedPrize;
            uint96 prize = uint96(address(this).balance - msg.value) - unclaimedPrize_;
            unclaimedPrize = unclaimedPrize_ + prize;
            prevSeason.unclaimedPrize = prize;
            prevSeason.winner = prevWinner;
            emit WinnerDeclared(prevSeasonIdx, prevWinner, prize);
        }
        uint32 seasonIdx = prevSeasonIdx + 1;
        currentSeasonIdx = seasonIdx;
        _seasons[seasonIdx].pubKey = seasonPubKey;
        emit SeasonStarted(seasonIdx, seasonPubKey);
    }

    function endSeason(uint32 seasonIdx, bytes32 seasonPrivKey)
        external
        payable
        onlyFrom(HOST)
    {
        if (seasonPrivKey == 0) revert InvalidKeyError();
        SeasonInfo storage season = _seasons[seasonIdx];
        if (_isSeasonClosed(season)) revert SeasonClosedError();
        season.privKey = seasonPrivKey;
        emit SeasonClosed(seasonIdx, seasonPrivKey);
    }

    function claim(uint32 seasonIdx, address payable recipient) external {
        SeasonInfo storage season = _seasons[seasonIdx];
        if (season.winner != msg.sender) revert NotWinnerError();
        uint96 prize = season.unclaimedPrize;
        if (prize == 0) revert AlreadyClaimedError();
        season.unclaimedPrize = 0;
        unclaimedPrize -= prize; 
        _transferEth(recipient, prize);
        emit PrizeClaimed(seasonIdx, msg.sender, prize);
    }

    receive() payable external {}

    function _isSeasonClosed(SeasonInfo storage season) private view returns (bool) {
        return season.privKey != bytes32(0);
    }

    function _consumeConfirmation(address registrant, Confirmation memory confirmation) private {
        bytes32 h = LibContest.hashRegistration(
            address(this),
            block.chainid,
            registrant,confirmation
        );
        if (confirmationConsumedBlock[h] != 0) revert ConfirmationConsumedError();
        confirmationConsumedBlock[h] = block.number;
        address signer = ecrecover(h, confirmation.v, confirmation.r, confirmation.s);
        if (signer == address(0) || signer != REGISTRAR) revert InvalidConfirmationError();
    }

    function _transferEth(address payable recipient, uint256 amount) private {
        (bool s, bytes memory r) = recipient.call{value: amount}("");
        if (!s) {
            assembly ("memory-safe") { 
                revert(add(r, 0x20), mload(r))
            }
        }
    }
}