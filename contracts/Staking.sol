// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/Address.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/SafeERC20.sol";

interface IStakedMint is IERC20 {
    function rebase( uint256 profit_, uint epoch_) external returns (uint256);

    function circulatingSupply() external view returns (uint256);

    function balanceOf(address who) external view override returns (uint256);

    function gonsForBalance( uint amount ) external view returns ( uint );

    function balanceForGons( uint gons ) external view returns ( uint );
    
    function index() external view returns ( uint );
}

interface IWarmup {
    function retrieve( address staker_, uint amount_ ) external;
}

interface IDistributor {
    function distribute() external returns ( bool );
}

contract TimeStaking is Ownable {

    using LowGasSafeMath for uint256;
    using LowGasSafeMath for uint32;
    using SafeERC20 for IERC20;
    using SafeERC20 for IStakedMint;

    IERC20 public immutable MINT;
    IStakedMint public immutable Memories;

    struct Epoch {
        uint number;
        uint distribute;
        uint32 length;
        uint32 endTime;
    }
    Epoch public epoch;

    IDistributor public distributor;
    
    uint public totalBonus;
    
    IWarmup public warmupContract;
    uint public warmupPeriod;

    event LogStake(address indexed recipient, uint256 amount);
    event LogClaim(address indexed recipient, uint256 amount);
    event LogForfeit(address indexed recipient, uint256 memoAmount, uint256 timeAmount);
    event LogDepositLock(address indexed user, bool locked);
    event LogUnstake(address indexed recipient, uint256 amount);
    event LogRebase(uint256 distribute);
    event LogSetContract(CONTRACTS contractType, address indexed _contract);
    event LogWarmupPeriod(uint period);
    
    constructor ( 
        address _Mint, 
        address _Memories, 
        uint32 _epochLength,
        uint _firstEpochNumber,
        uint32 _firstEpochTime
    ) {
        require( _Mint != address(0) );
        MINT = IERC20(_Mint);
        require( _Memories != address(0) );
        Memories = IStakedMint(_Memories);
        
        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endTime: _firstEpochTime,
            distribute: 0
        });
    }

    struct Claim {
        uint deposit;
        uint gons;
        uint expiry;
        bool lock; // prevents malicious delays
    }
    mapping( address => Claim ) public warmupInfo;

    /**
        @notice stake MINT to enter warmup
        @param _amount uint
        @return bool
     */
    function stake( uint _amount, address _recipient ) external returns ( bool ) {
        rebase();
        
        MINT.safeTransferFrom( msg.sender, address(this), _amount );

        Claim memory info = warmupInfo[ _recipient ];
        require( !info.lock, "Deposits for account are locked" );

        warmupInfo[ _recipient ] = Claim ({
            deposit: info.deposit.add( _amount ),
            gons: info.gons.add( Memories.gonsForBalance( _amount ) ),
            expiry: epoch.number.add( warmupPeriod ),
            lock: false
        });
        
        Memories.safeTransfer( address(warmupContract), _amount );
        emit LogStake(_recipient, _amount);
        return true;
    }

    /**
        @notice retrieve sMINT from warmup
        @param _recipient address
     */
    function claim ( address _recipient ) external {
        Claim memory info = warmupInfo[ _recipient ];
        if ( epoch.number >= info.expiry && info.expiry != 0 ) {
            delete warmupInfo[ _recipient ];
            uint256 amount = Memories.balanceForGons( info.gons );
            warmupContract.retrieve( _recipient,  amount);
            emit LogClaim(_recipient, amount);
        }
    }

    /**
        @notice forfeit sMINT in warmup and retrieve MINT
     */
    function forfeit() external {
        Claim memory info = warmupInfo[ msg.sender ];
        delete warmupInfo[ msg.sender ];
        uint memoBalance = Memories.balanceForGons( info.gons );
        warmupContract.retrieve( address(this),  memoBalance);
        MINT.safeTransfer( msg.sender, info.deposit);
        emit LogForfeit(msg.sender, memoBalance, info.deposit);
    }

    /**
        @notice prevent new deposits to address (protection from malicious activity)
     */
    function toggleDepositLock() external {
        warmupInfo[ msg.sender ].lock = !warmupInfo[ msg.sender ].lock;
        emit LogDepositLock(msg.sender, warmupInfo[ msg.sender ].lock);
    }

    /**
        @notice redeem sMINT for MINT
        @param _amount uint
        @param _trigger bool
     */
    function unstake( uint _amount, bool _trigger ) external {
        if ( _trigger ) {
            rebase();
        }
        Memories.safeTransferFrom( msg.sender, address(this), _amount );
        MINT.safeTransfer( msg.sender, _amount );
        emit LogUnstake(msg.sender, _amount);
    }

    /**
        @notice returns the sMINT index, which tracks rebase growth
        @return uint
     */
    function index() external view returns ( uint ) {
        return Memories.index();
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if( epoch.endTime <= uint32(block.timestamp) ) {

            Memories.rebase( epoch.distribute, epoch.number );

            epoch.endTime = epoch.endTime.add32( epoch.length );
            epoch.number++;
            
            if ( address(distributor) != address(0) ) {
                distributor.distribute();
            }

            uint balance = contractBalance();
            uint staked = Memories.circulatingSupply();

            if( balance <= staked ) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub( staked );
            }
            emit LogRebase(epoch.distribute);
        }
    }

    /**
        @notice returns contract MINT holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns ( uint ) {
        return MINT.balanceOf( address(this) ).add( totalBonus );
    }

    enum CONTRACTS { DISTRIBUTOR, WARMUP }

    /**
        @notice sets the contract address for LP staking
        @param _contract address
     */
    function setContract( CONTRACTS _contract, address _address ) external onlyOwner {
        if( _contract == CONTRACTS.DISTRIBUTOR ) { // 0
            distributor = IDistributor(_address);
        } else if ( _contract == CONTRACTS.WARMUP ) { // 1
            require( address(warmupContract) == address( 0 ), "Warmup cannot be set more than once" );
            warmupContract = IWarmup(_address);
        }
        emit LogSetContract(_contract, _address);
    }
    
    /**
     * @notice set warmup period in epoch's numbers for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup( uint _warmupPeriod ) external onlyOwner {
        warmupPeriod = _warmupPeriod;
        emit LogWarmupPeriod(_warmupPeriod);
    }
}