pragma solidity ^0.8.4;

import './extensions/ERC721AQueryable.sol';

/**
 * @title TheBook
 *
 * @dev USE [ERC721A](https://www.erc721a.org/)
 */
contract TheBook is ERC721AQueryable {
    constructor() ERC721AQueryable(){}

    function mint(uint256 quantity) external{
        _mint(msg.sender, quantity);
    }
}
