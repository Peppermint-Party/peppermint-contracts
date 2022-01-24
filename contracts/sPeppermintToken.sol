// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/Address.sol";

string constant TOKEN_NAME = "Staked Peppermint";
string constant TOKEN_SYMBOL = "sMINT";

contract sPeppermintToken is ERC20Permit, Ownable {
  using LowGasSafeMath for uint256;

  struct Rebase {
    uint256 epoch;
    uint256 rebase; // 18 decimals
    uint256 totalStakedBefore;
    uint256 totalStakedAfter;
    uint256 amountRebased;
    uint256 index;
    uint32 timeOccured;
  }

  address public _stakingContract;
  address public _initializer;

  event LogSupply(uint256 indexed epoch, uint256 timestamp, uint256 totalSupply);
  event LogRebase(uint256 indexed epoch, uint256 rebase, uint256 index);
  event LogStakingContractUpdated(address stakingContract);
  event LogSetIndex(uint256 indexed index);    

  Rebase[] public rebases;

  uint256 public INDEX;

  uint256 private constant MAX_UINT256 = ~uint256(0);
  uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 5000000 * 10**9;

  // TOTAL_GONS is a multiple of INITIAL_FRAGMENTS_SUPPLY so that _gonsPerFragment is an integer.
  // Use the highest value that fits in a uint256 for max granularity.
  uint256 private constant TOTAL_GONS =
    MAX_UINT256 - (MAX_UINT256 % INITIAL_FRAGMENTS_SUPPLY);

  // MAX_SUPPLY = maximum integer < (sqrt(4*TOTAL_GONS + 1) - 1) / 2
  uint256 private constant MAX_SUPPLY = ~uint128(0); // (2^128) - 1

  uint256 private _gonsPerFragment;
  mapping(address => uint256) private _gonBalances;

  mapping(address => mapping(address => uint256)) private _allowedValue;

  constructor() 
      ERC20(TOKEN_NAME, TOKEN_SYMBOL) 
      ERC20Permit(TOKEN_NAME) {
        
    // Assign the initializer as the address that deployed the contract.
    _initializer = msg.sender;

    // _totalSupply = INITIAL_FRAGMENTS_SUPPLY;
    // _gonsPerFragment = TOTAL_GONS.div(_totalSupply);
  }

  function decimals() public pure override returns (uint8) {
    return 9;
  }

  function initialize(address stakingContract_) external onlyInitializer returns (bool) {
    require(msg.sender == _initializer, "NA");
    require(stakingContract_ != address(0), "IA");

    _stakingContract = stakingContract_;
    _gonBalances[_stakingContract] = TOTAL_GONS;

    _mint(_stakingContract, INITIAL_FRAGMENTS_SUPPLY); // moved here from constructor because of _stackingContract
    _gonsPerFragment = TOTAL_GONS.div(totalSupply());

    emit Transfer(address(0x0), _stakingContract, totalSupply());
    emit LogStakingContractUpdated(stakingContract_);

    _initializer = address(0);
    return true;
  }

  function setIndex(uint256 _INDEX) external onlyOwner {
    require(INDEX == 0, "INZ");
    INDEX = gonsForBalance(_INDEX);
    emit LogSetIndex(INDEX);
  }

  /**
   * @notice increases sPeppermintToken supply to increase staking balances relative to profit_
   * @param profit_ uint256
   * @return uint256
   */
  function rebase(uint256 profit_, uint256 epoch_)
    public
    onlyStakingContract
    returns (uint256)
  {
    uint256 rebaseAmount;
    uint256 circulatingSupply_ = circulatingSupply();

    if (profit_ == 0) {
      emit LogSupply(epoch_, block.timestamp, totalSupply());
      emit LogRebase(epoch_, 0, index());
      return totalSupply();
    } else if (circulatingSupply_ > 0) {
      rebaseAmount = profit_.mul(totalSupply()).div(circulatingSupply_);
    } else {
      rebaseAmount = profit_;
    }

    // _totalSupply = _totalSupply.add(rebaseAmount);
    _mint(msg.sender, rebaseAmount);

    if (totalSupply() > MAX_SUPPLY) {
    //   _totalSupply = MAX_SUPPLY;
        uint256 amountToBeBurned = totalSupply() - MAX_SUPPLY;
        _burn(msg.sender, amountToBeBurned);
    }

    _gonsPerFragment = TOTAL_GONS.div(totalSupply());

    _storeRebase(circulatingSupply_, profit_, epoch_);

    return totalSupply();
  }

  /**
   * @notice emits event with data about rebase
   * @param previousCirculating_ uint
   * @param profit_ uint
   * @param epoch_ uint
   * @return bool
   */
  function _storeRebase(
    uint256 previousCirculating_,
    uint256 profit_,
    uint256 epoch_
  ) internal returns (bool) {
    uint256 rebasePercent = profit_.mul(1e18).div(previousCirculating_);

    rebases.push(
      Rebase({
        epoch: epoch_,
        rebase: rebasePercent, // 18 decimals
        totalStakedBefore: previousCirculating_,
        totalStakedAfter: circulatingSupply(),
        amountRebased: profit_,
        index: index(),
        timeOccured: uint32(block.timestamp)
      })
    );

    emit LogSupply(epoch_, block.timestamp, totalSupply());
    emit LogRebase(epoch_, rebasePercent, index());

    return true;
  }

  function balanceOf(address who) public view override returns (uint256) {
    return _gonBalances[who].div(_gonsPerFragment);
  }

  function gonsForBalance(uint256 amount) public view returns (uint256) {
    return amount.mul(_gonsPerFragment);
  }

  function balanceForGons(uint256 gons) public view returns (uint256) {
    return gons.div(_gonsPerFragment);
  }

  // Staking contract holds excess sPeppermintToken
  function circulatingSupply() public view returns (uint256) {
    return totalSupply().sub(balanceOf(_stakingContract));
  }

  function index() public view returns (uint256) {
    return balanceForGons(INDEX);
  }

  function transfer(address to, uint256 value) public override returns (bool) {
    uint256 gonValue = value.mul(_gonsPerFragment);
    _gonBalances[msg.sender] = _gonBalances[msg.sender].sub(gonValue);
    _gonBalances[to] = _gonBalances[to].add(gonValue);
    emit Transfer(msg.sender, to, value);
    return true;
  }

  function allowance(address owner_, address spender)
    public
    view
    override
    returns (uint256)
  {
    return _allowedValue[owner_][spender];
  }

  function transferFrom(
    address from,
    address to,
    uint256 value
  ) public override returns (bool) {
    _allowedValue[from][msg.sender] = _allowedValue[from][msg.sender].sub(value);
    emit Approval(from, msg.sender, _allowedValue[from][msg.sender]);

    uint256 gonValue = gonsForBalance(value);
    _gonBalances[from] = _gonBalances[from].sub(gonValue);
    _gonBalances[to] = _gonBalances[to].add(gonValue);
    emit Transfer(from, to, value);

    return true;
  }

  function approve(address spender, uint256 value)
    public
    override
    returns (bool)
  {
    _allowedValue[msg.sender][spender] = value;
    emit Approval(msg.sender, spender, value);
    return true;
  }

  // What gets called in a permit
  function _approve(
    address owner,
    address spender,
    uint256 value
  ) internal virtual override {
    _allowedValue[owner][spender] = value;
    emit Approval(owner, spender, value);
  }

  function increaseAllowance(address spender, uint256 addedValue)
    public
    override
    returns (bool)
  {
    _allowedValue[msg.sender][spender] = _allowedValue[msg.sender][spender].add(addedValue);
    emit Approval(msg.sender, spender, _allowedValue[msg.sender][spender]);
    return true;
  }

  function decreaseAllowance(address spender, uint256 subtractedValue)
    public
    override
    returns (bool)
  {
    uint256 oldValue = _allowedValue[msg.sender][spender];
    if (subtractedValue >= oldValue) {
      _allowedValue[msg.sender][spender] = 0;
    } else {
      _allowedValue[msg.sender][spender] = oldValue.sub(subtractedValue);
    }
    emit Approval(msg.sender, spender, _allowedValue[msg.sender][spender]);
    return true;
  }

  modifier onlyStakingContract() {
    require(msg.sender == _stakingContract, "OSC");
    _;
  }

  modifier onlyInitializer() {
    require(msg.sender == _initializer, "OI");
    _;
  }
}
