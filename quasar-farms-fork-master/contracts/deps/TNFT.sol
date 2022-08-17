// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract TestNFT is ERC721, ERC721Burnable, Ownable {
    using Counters for Counters.Counter;

    Counters.Counter private _tokenIdCounter;

    constructor() ERC721("TestNFT", "TNFT") {}

    function safeMint(address to) public onlyOwner {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(to, tokenId);
    }
    
    function mintNum(address to, uint256 num) public onlyOwner  {
        for (uint i=0; i < num; i++) {
            safeMint(to);
        }
    }

    function batchAprove(uint256[] memory _nids, address _spender) public { 
        for (uint i=0; i < _nids.length; i++) {
            approve(_spender, _nids[i]);
        }
    }
}