// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GoldfishToken is ERC20 {
    constructor() ERC20("Goldfish", "GFISH") {
        _mint(msg.sender, 0);
    }

    function mint(uint256 _lp) public {
        _mint(msg.sender, _lp);
    }
}
