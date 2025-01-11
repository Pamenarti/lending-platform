// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IInterestRateModel {
    function getBorrowRate(uint256 totalSupply, uint256 totalBorrows)
        external
        view
        returns (uint256);
} 