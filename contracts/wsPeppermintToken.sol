// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/Address.sol";
import "./libraries/SafeERC20.sol";

interface IStakedMint is IERC20, IERC20Metadata {
    function index() external view returns ( uint );
}

contract wsPeppermintToken is ERC20 {
    using SafeERC20 for IStakedMint;
    using LowGasSafeMath for uint;

    IStakedMint public immutable sMINT;
    event Wrap(address indexed recipient, uint256 amountMemo, uint256 amountWmemo);
    event UnWrap(address indexed recipient,uint256 amountWmemo, uint256 amountMemo);

    constructor( address _sMINT ) ERC20( "Wrapped sMINT", "wsMINT" ) {
        require( _sMINT != address(0) );
        sMINT = IStakedMint(_sMINT);
    }

    /**
        @notice wrap sMINT
        @param _amount uint
        @return uint
     */
    function wrap( uint _amount ) external returns ( uint ) {
        sMINT.safeTransferFrom( msg.sender, address(this), _amount );
        
        uint value = MEMOTowMEMO( _amount );
        _mint( msg.sender, value );
        emit Wrap(msg.sender, _amount, value);
        return value;
    }

    /**
        @notice unwrap sMINT
        @param _amount uint
        @return uint
     */
    function unwrap( uint _amount ) external returns ( uint ) {
        _burn( msg.sender, _amount );

        uint value = wMEMOToMEMO( _amount );
        sMINT.safeTransfer( msg.sender, value );
        emit UnWrap(msg.sender, _amount, value);
        return value;
    }

    /**
        @notice converts wsPeppermintToken amount to sMINT
        @param _amount uint
        @return uint
     */
    function wMEMOToMEMO( uint _amount ) public view returns ( uint ) {
        return _amount.mul( sMINT.index() ).div( 10 ** decimals() );
    }

    /**
        @notice converts sMINT amount to wsPeppermintToken
        @param _amount uint
        @return uint
     */
    function MEMOTowMEMO( uint _amount ) public view returns ( uint ) {
        return _amount.mul( 10 ** decimals() ).div( sMINT.index() );
    }

}