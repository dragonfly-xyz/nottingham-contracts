// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

library LibAddress {
    function safeCall(
        address payable target,
        uint256 value,
        bytes memory callData,
        bool checkTarget,
        uint256 callGas,
        uint256 maxReturnDataSize
    )
        internal returns (bool success, bytes memory resultData)
    {
        if (checkTarget && target.code.length == 0) {
            return (false, '');
        }
        assembly { 
            resultData := mload(0x40)
            success := call(
                callGas,
                target,
                value,
                add(callData, 0x20),
                mload(callData),
                add(resultData, 0x20),
                maxReturnDataSize
            )
            mstore(resultData, returndatasize())
            mstore(0x40, add(add(resultData, 0x20), returndatasize()))
        }
    }

    function safeCall(
        address target,
        bytes memory callData,
        bool checkTarget,
        uint256 callGas,
        uint256 maxReturnDataSize
    )
        internal returns (bool success, bytes memory resultData)
    {
        return safeCall(payable(target), 0, callData, checkTarget, callGas, maxReturnDataSize);
    }

    function safeStaticCall(
        address target,
        bytes memory callData,
        bool checkTarget,
        uint256 callGas,
        uint256 maxReturnDataSize
    )
        internal view returns (bool success, bytes memory resultData)
    {
        if (checkTarget && target.code.length == 0) {
            return (false, '');
        }
        assembly { 
            resultData := mload(0x40)
            success := staticcall(
                callGas,
                target,
                add(callData, 0x20),
                mload(callData),
                add(resultData, 0x20),
                maxReturnDataSize
            )
            mstore(resultData, returndatasize())
            mstore(0x40, add(add(resultData, 0x20), returndatasize()))
        }
    }
}
