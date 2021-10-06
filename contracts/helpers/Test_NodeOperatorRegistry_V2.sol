// SPDX-FileCopyrightText: 2021 Shardlabs
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "../NodeOperatorRegistry.sol";

/// @title NodeOperatorRegistryV2
/// @dev this contract is used only for test the upgradibility
contract NodeOperatorRegistryV2 is NodeOperatorRegistry {
    uint256 x;
    
    function version() public override pure returns (string memory) {
        return "2.0.0";
    }
}