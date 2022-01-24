// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// import "./IERC20.sol";
import "./IERC20Mintable.sol";

interface IMintableToken is IERC20Mintable, IERC20, IERC20Metadata {
    function burnFrom(address account_, uint256 amount_) external;
}