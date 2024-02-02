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
    address payable winner;
    mapping (address player => bytes32 codeHash) playerCodeHashes;
}
    
library LibContest {
    bytes32 constant private REGISTRATION_PREFIX = keccak256(unicode"ᴙɘgiꙅTᴙATioᴎ");

    function hashRegistration(address registrant, uint256 chainId, Confirmation memory confirmation)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(
            REGISTRATION_PREFIX,
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

    event Registered(address indexed player);
    event Retired(address indexed player);
    event SeasonEnded(uint256 indexed season, bytes32 privateKey);
    event WinnerDeclared(uint256 indexed season, address indexed winner, uint256 prize);
    event SeasonStarted(uint256 indexed season, bytes32 publicKey);
    event PrizeClaimed(uint256 indexed season, address indexed winner, uint256 prize);
    event CodeCommitted(uint256 indexed season, address indexed player, bytes encryptedCode);

    address public immutable HOST;
    address public immutable ADMIN;
    address public immutable REGISTRAR;

    uint256 public currentSeason;
    mapping (uint256 seasonIdx => SeasonInfo info) private _seasons;
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

    modifier onlyDuringSeason(uint256 seasonIdx) {
        if (seasonIdx != currentSeason) revert NotSeasonError();
        _;
    }
    
    function retire(address payable player) external onlyFrom(ADMIN) {
        if (playerRegisteredBlock[player] != 0) {
            playerRegisteredBlock[player] = block.number;
            emit Retired(player);
        }
    }

    function register(Confirmation memory confirmation) external {
        if (playerRegisteredBlock[msg.sender] == 0) {
            _consumeConfirmation(msg.sender, confirmation);
            playerRegisteredBlock[msg.sender] = block.number;
            emit Registered(msg.sender);
        }
    }

    function setPlayerCode(uint256 seasonIdx, bytes memory encryptedCode)
        external
        onlyRegisteredPlayer
        onlyDuringSeason(seasonIdx)
    {
        // TODO: reject if inbetween seasons.
        _seasons[seasonIdx].playerCodeHashes[msg.sender] = keccak256(encryptedCode);
        emit CodeCommitted(seasonIdx, msg.sender, encryptedCode);
    }

    function getPlayerCodeHash(uint256 seasonIdx, address player)
        external view returns (bytes32 codeHash)
    {
        return _seasons[seasonIdx].playerCodeHashes[player];
    }

    function newSeason(
        uint256 prevSeasonIdx,
        bytes32 seasonPubKey_,
        address prevWinner
    )
        external
        payable
        onlyFrom(HOST)
    {

    }

    function endSeason(uint256 seasonIdx, bytes32 seasonPrivKey_) external payable onlyFrom(HOST) {}
    function claim(address payable recipient) external {}
    receive() payable external {}

    function _consumeConfirmation(address registrant, Confirmation memory confirmation) private {
        bytes32 h = LibContest.hashRegistration(registrant, block.chainid, confirmation);
        if (confirmationConsumedBlock[h] != 0) revert ConfirmationConsumedError();
        confirmationConsumedBlock[h] = block.number;
        address signer = ecrecover(h, confirmation.v, confirmation.r, confirmation.s);
        if (signer == address(0) || signer != REGISTRAR) revert InvalidConfirmationError();
    }
}