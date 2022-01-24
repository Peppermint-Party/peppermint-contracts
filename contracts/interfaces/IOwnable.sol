

interface IOwnable {
  function owner() external view returns (address);

  function renounceOwnership() external;
  
  function transferOwnership( address newOwner_ ) external;
}