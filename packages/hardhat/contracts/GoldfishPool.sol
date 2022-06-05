// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./GoldfishToken.sol";

import "./utils/Math.sol";

contract GoldfishPool is Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    GoldfishToken poolToken;

    address alfajoresCUSD = 0x874069Fa1Eb16D44d622F2e0Ca25eeA172369bC1;

    enum Reputation {
        High,
        Medium,
        Low,
        None
    }

    struct Loan {
        address borrower;
        uint256 amount;
        bool approved;  
    }

    struct Approver {
        uint256 balance;
        uint256 approvalLimit;   
        uint256 currentlyApproved;
    }

    struct Borrower {
        uint256 borrowLimit;
        uint256 currentlyBorrowed;
        uint256[] loans;
    }


    uint lendingRateAPR; // in -10^18 or wei
    Counters.Counter currentId;
    mapping (address => Approver) approvers;
    mapping (address => Borrower) borrowers;
    mapping (uint256 => Loan) loans;
    

    uint256 totalShares; // total shares of LP tokens
    uint maxLoanAmount;
    uint256 maxTimePeriod; //in days
    uint256 minPoolAllocation; // per 10^18

    /**************************************************************************
     * Events
     *************************************************************************/

    event DepositMade(address indexed poolProvider, uint256 amount, uint256 shares);
    event NewLoanRequest(address indexed borrower, uint256 loanId, uint256 amount);
    event LoanApproved(address indexed approver, address indexed borrower, uint256 loanId,  uint256 amount);

    /**************************************************************************
     * Constructor
     *************************************************************************/

    constructor(address _tokenAddr) public {
        poolToken = GoldfishToken(_tokenAddr);
        lendingRateAPR = 10^17;
        maxLoanAmount = 0;
        maxTimePeriod = 60;
        minPoolAllocation = 10^15;
        totalShares = 0;
    }

    /**************************************************************************
     * Modifiers
    *************************************************************************/

    modifier onlyApprover() {
        require(approvers[msg.sender].balance > 0, "Must be an approver");
        _;
    }

    /**************************************************************************
     * Utility Functions
     *************************************************************************/


    function getLendingRate() public view returns (uint256){
        return lendingRateAPR;
    }

    function setLendingRate(uint256 _lendingRateAPR) public onlyOwner {
        lendingRateAPR = _lendingRateAPR;
    }

    function getRepayAmount(address _borrower) public view returns (uint256){
        // TODO
        // require(loans[_borrower].approved, "Loan not approved");
        // return loans[_borrower].amount + Math.calculateInterest(loans[_borrower], lendingRateAPR, 1);
    }

    function getPoolShare(uint256 _amt) public view returns (uint256){
        uint256 share = (_amt * 1e18) / (_amt + totalShares);
        return share;
    }

    function getTotalShares() public view returns (uint256){
        return poolToken.totalSupply();
    }

    function getPoolReserves() public view returns (uint256){
        return getCUSD(alfajoresCUSD).balanceOf(address(this));
    }

    function mintNewShares(uint256 _amt) public onlyApprover {
        poolToken.mint(_amt);
    }


    function getCUSD(address _addr) internal view returns (IERC20){
        return IERC20(_addr);
    }

    function doCUSDTransfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        require(to != address(0), "Can't send to zero address");
        IERC20 cusd = getCUSD(alfajoresCUSD);
        return cusd.transferFrom(from, to, amount);
    }

    function assessCredit(address _addr) public view returns (uint) {
        // TODO
        return 0;
    }

    function getInitialBorrowLimit() public view returns (uint256){
        return Math.mulDiv(getPoolReserves(), minPoolAllocation, 10**18);
    }

    function loanAlreadyExists(address _bAddr, uint256 _loanId) public view returns (bool){
        Borrower memory borrower = borrowers[_bAddr];
        for (uint i=0; i< borrower.loans.length; i++){
            if (borrower.loans[i] == _loanId){
                return true;
            }
        }
        return false;
    }

    /**************************************************************************
     * Core Functions
     *************************************************************************/

    function deposit(uint256 _amt) external  {
        require(_amt > 0, "Must deposit more than zero");
        uint256 depositShare = getPoolShare(_amt);
        
        bool success = doCUSDTransfer(msg.sender, address(this), _amt);
        require(success, "Failed to transfer for deposit");
        mintNewShares(depositShare);
        
        if (approvers[msg.sender].balance == 0) {
            approvers[msg.sender] = Approver(_amt, _amt, 0);
        } else {
            approvers[msg.sender].balance += _amt;
            approvers[msg.sender].approvalLimit += _amt;
        }

        emit DepositMade(msg.sender, _amt, depositShare);
    }

    function approve(uint256 _loanId) public onlyApprover {
        Loan storage loan = loans[_loanId];
        require(loan.amount == 0, "Invalid loan");
        require(loan.approved == true, "Loan already approved");
        require(approvers[msg.sender].approvalLimit > loan.amount + approvers[msg.sender].currentlyApproved, "Going over your approval limit");
        loan.approved = true;

        Borrower storage borrower = borrowers[loan.borrower];
        require(borrower.borrowLimit == 0, "Borrower doesn't exist");
        require(loanAlreadyExists(loan.borrower, _loanId), "Loan already exists");

        borrower.loans.push(_loanId);
        borrower.currentlyBorrowed += loan.amount;
        loans[_loanId].approved = true;

        approvers[msg.sender].currentlyApproved += loan.amount;

        bool success = doCUSDTransfer(address(this), msg.sender, loan.amount);
        require(success, "Failed to transfer for deposit");

        emit LoanApproved(msg.sender, msg.sender, _loanId, loan.amount);
    }

    function requestBorrow(uint256 _amt) external {
        require(_amt > 0, "Must borrow more than zero");

        Borrower storage borrower = borrowers[msg.sender];
        if (borrower.borrowLimit == 0) {
            borrower.borrowLimit = getInitialBorrowLimit();
            borrower.currentlyBorrowed = 0;
        }
        require(_amt + borrower.currentlyBorrowed < borrower.borrowLimit, "Going over your borrow limit");

        uint256 loanId = currentId.current();
        loans[loanId] = Loan(msg.sender, _amt, false);
        currentId.increment();

        emit NewLoanRequest(msg.sender, loanId, _amt);
    }

    // function repay() external {
    //     // TODO: check if struct exists
    //     require(loans[] > 0, "Not borrowing");
    //     require(loans[msg.sender].approved, "Not approved");

    //     uint256 repayAmount = getRepayAmount(msg.sender);
    //     bool success = doCUSDTransfer(msg.sender, address(this), repayAmount);
    //     require(success, "Failed to transfer for deposit");
    //     loans[msg.sender] = 0;
    //     // updateReputation();
    // }

    

    function checkDefault() public returns (bool) {
        return false;
    }
}