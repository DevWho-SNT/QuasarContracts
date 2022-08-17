pragma solidity =0.5.16;

import '../QuasarERC20.sol';

contract ERC20 is QuasarERC20 {
    constructor(uint _totalSupply) public {
        _mint(msg.sender, _totalSupply);
    }
}
