// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IWhiteLightAggregator.sol";

contract WhiteLightAggregator is AccessControl, IWhiteLightAggregator {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE"); // role allowed to submit the data
    uint256 public minConfirmations; // minimal required confimations
    bytes[2] public utilityBytes; // the part of the transaction payload; ["[[aggregatorAddr]]80a4","388080"]

    mapping(address => bool) public isOracle; // oracle address => oracle details

    modifier onlyAdmin {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "onlyAdmin: bad role");
        _;
    }

    struct SubmissionInfo {
        bool confirmed; // whether is confirmed
        uint256 confirmations; // received confirmations count
        mapping(address => bool) hasVerified; // verifier => has already voted
    }

    mapping(bytes32 => SubmissionInfo) public getMintInfo; // mint id => submission info
    mapping(bytes32 => SubmissionInfo) public getBurntInfo; // burnt id => submission info

    event Confirmed(bytes32 submissionId, address operator); // emitted once the submission is confirmed
    event SubmissionApproved(bytes32 submissionId); // emitted once the submission is confirmed

    /// @dev Constructor that initializes the most important configurations.
    /// @param _minConfirmations Minimal required confirmations.
    /// @param _utilityBytes Utility bytes to be inserted into the transaction payload.
    constructor(uint256 _minConfirmations, bytes[2] memory _utilityBytes) {
        minConfirmations = _minConfirmations;
        utilityBytes = _utilityBytes;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev Confirms the mint request.
    /// @param _mintId Submission identifier.
    /// @param _trxData Array of transactions by oracles of 2 elements - payload up to the receiver address and the signature bytes.
    function submitMint(bytes32 _mintId, bytes[2][] memory _trxData)
        external
        override
        returns (bool)
    {
        SubmissionInfo storage mintInfo = getMintInfo[_mintId];
        for (uint256 i = 0; i < _trxData.length; i++) {
            bytes memory unsignedTrx =
                getUnsignedTrx(_trxData[i][0], hex"0b29b943", _mintId);
            address oracle =
                recoverSigner(keccak256(unsignedTrx), _trxData[i][1]);
            require(hasRole(ORACLE_ROLE, oracle), "onlyOracle: bad role");
            require(!mintInfo.hasVerified[oracle], "submit: submitted already");
            mintInfo.confirmations += 1;
            mintInfo.hasVerified[oracle] = true;
            if (mintInfo.confirmations >= minConfirmations) {
                mintInfo.confirmed = true;
                emit SubmissionApproved(_mintId);
            }
            emit Confirmed(_mintId, oracle);
        }
        return mintInfo.confirmed;
    }

    /// @dev Confirms the burnnt request.
    /// @param _burntId Submission identifier.
    /// @param _trxData Array of transactions by oracles of 2 elements - payload up to the receiver address and the signature bytes.
    function submitBurn(bytes32 _burntId, bytes[2][] memory _trxData)
        external
        override
        returns (bool)
    {
        SubmissionInfo storage burnInfo = getBurntInfo[_burntId];
        for (uint256 i = 0; i < _trxData.length; i++) {
            bytes memory unsignedTrx =
                getUnsignedTrx(_trxData[i][0], hex"c4b56cd0", _burntId);
            address oracle =
                recoverSigner(keccak256(unsignedTrx), _trxData[i][1]);
            require(hasRole(ORACLE_ROLE, oracle), "onlyOracle: bad role");
            require(!burnInfo.hasVerified[oracle], "submit: submitted already");
            burnInfo.confirmations += 1;
            burnInfo.hasVerified[oracle] = true;
            if (burnInfo.confirmations >= minConfirmations) {
                burnInfo.confirmed = true;
                emit SubmissionApproved(_burntId);
            }
            emit Confirmed(_burntId, oracle);
        }
        return burnInfo.confirmed;
    }

    /// @dev Sets minimal required confirmations.
    /// @param _minConfirmations Minimal required confirmations.
    function setMinConfirmations(uint256 _minConfirmations) external onlyAdmin {
        minConfirmations = _minConfirmations;
    }

    /// @dev Add new oracle.
    /// @param _oracle Oracle address.
    function addOracle(address _oracle) external onlyAdmin {
        grantRole(ORACLE_ROLE, _oracle);
        isOracle[_oracle] = true;
    }

    /// @dev Remove oracle.
    /// @param _oracle Oracle address.
    function removeOracle(address _oracle) external onlyAdmin {
        revokeRole(ORACLE_ROLE, _oracle);
    }

    /// @dev Returns whether mint request is confirmed.
    /// @param _mintId Submission identifier.
    /// @return Whether mint request is confirmed.
    function isMintConfirmed(bytes32 _mintId)
        external
        view
        override
        returns (bool)
    {
        return getMintInfo[_mintId].confirmed;
    }

    /// @dev Returns whether burnnt request is confirmed.
    /// @param _burntId Submission identifier.
    /// @return Whether burnnt request is confirmed.
    function isBurntConfirmed(bytes32 _burntId)
        external
        view
        override
        returns (bool)
    {
        return getBurntInfo[_burntId].confirmed;
    }

    /// @dev Prepares raw transacton that was signed by the oracle.
    /// @param _payloadPart First part of the transaction; rlp encoded (nonce + gasprice + startgas) + length of the next rlp encoded element (recipient).
    /// @param _method The function identifier called by the oracle for the confirmation.
    /// @param _submissionId Submission identifier.
    function getUnsignedTrx(
        bytes memory _payloadPart,
        bytes memory _method,
        bytes32 _submissionId
    ) public view returns (bytes memory) {
        return
            concat(
                concat(
                    concat(concat(_payloadPart, utilityBytes[0]), _method),
                    abi.encodePacked(_submissionId)
                ),
                utilityBytes[1]
            );
    }

    /// @dev Recovers the signer of the msg.
    /// @param _msgHash The raw transaction hash.
    /// @param _signature Signature bytes in format r+s+v.
    function recoverSigner(bytes32 _msgHash, bytes memory _signature)
        public
        pure
        returns (address)
    {
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(_signature);

        return ecrecover(_msgHash, v, r, s);
    }

    /// @dev Splits signature bytes to r,s,v components.
    /// @param _signature Signature bytes in format r+s+v.
    function splitSignature(bytes memory _signature)
        public
        pure
        returns (
            bytes32 r,
            bytes32 s,
            uint8 v
        )
    {
        require(
            _signature.length == 65,
            "splitSignature: invalid signature length"
        );

        assembly {
            r := mload(add(_signature, 32))
            s := mload(add(_signature, 64))
            v := byte(0, mload(add(_signature, 96)))
        }
    }

    /// @dev Concats arbitrary bytes.
    /// @param _preBytes First byte array.
    /// @param _postBytes Second byte array.
    function concat(bytes memory _preBytes, bytes memory _postBytes)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory tempBytes;

        assembly {
            tempBytes := mload(0x40)

            let length := mload(_preBytes)
            mstore(tempBytes, length)
            let mc := add(tempBytes, 0x20)
            let end := add(mc, length)

            for {
                let cc := add(_preBytes, 0x20)
            } lt(mc, end) {
                mc := add(mc, 0x20)
                cc := add(cc, 0x20)
            } {
                mstore(mc, mload(cc))
            }

            length := mload(_postBytes)
            mstore(tempBytes, add(length, mload(tempBytes)))
            mc := end
            end := add(mc, length)

            for {
                let cc := add(_postBytes, 0x20)
            } lt(mc, end) {
                mc := add(mc, 0x20)
                cc := add(cc, 0x20)
            } {
                mstore(mc, mload(cc))
            }
            mstore(
                0x40,
                and(
                    add(add(end, iszero(add(length, mload(_preBytes)))), 31),
                    not(31)
                )
            )
        }

        return tempBytes;
    }
}