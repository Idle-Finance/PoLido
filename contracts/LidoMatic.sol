// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.7;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./interfaces/IValidatorShare.sol";
import "./interfaces/INodeOperatorRegistry.sol";
import "./interfaces/IStakeManager.sol";
import "./interfaces/ILidoNFT.sol";

contract LidoMatic is
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    event SubmitEvent(address indexed _from, uint256 indexed _amount);
    event RequestWithdrawEvent(address indexed _from, uint256 indexed _amount);
    event DistributeRewardsEvent(uint256 indexed _amount);
    event WithdrawTotalDelegatedEvent(
        address indexed _from,
        uint256 indexed _amount
    );
    event DelegateEvent(
        uint256 indexed _amountDelegated,
        uint256 indexed _remainder
    );
    event ClaimTokensEvent(
        address indexed _from,
        uint256 indexed _id,
        uint256 indexed _amountClaimed,
        uint256 _amountBurned
    );

    using SafeERC20Upgradeable for IERC20Upgradeable;

    INodeOperatorRegistry public nodeOperator;
    FeeDistribution public entityFees;
    IStakeManager public stakeManager;
    ILidoNFT public lidoNFT;

    string public version;
    address public dao;
    address public insurance;
    address public token;
    uint256 public lastWithdrawnValidatorId;
    uint256 public totalBuffered;
    uint256 public delegationLowerBound;
    uint256 public rewardDistributionLowerBound;
    uint256 public reservedFunds;
    uint256 public lockedAmountStMatic;
    uint256 public lockedAmountMatic;
    uint256 public minValidatorBalance;

    mapping(uint256 => RequestWithdraw) public token2WithdrawRequest;

    mapping(address => uint256) public validator2DelegatedAmount;

    bytes32 public constant DAO = keccak256("DAO");

    struct RequestWithdraw {
        uint256 amountToBurn;
        uint256 validatorNonce;
        uint256 requestTime;
        address validatorAddress;
    }

    struct FeeDistribution {
        uint8 dao;
        uint8 operators;
        uint8 insurance;
    }

    // Document the remaining arguments
    /**
     * @param _token - Address of MATIC token on Ethereum Mainnet
     * @param _nodeOperator - Address of the node operator
     */
    function initialize(
        address _nodeOperator,
        address _token,
        address _dao,
        address _insurance,
        address _stakeManager,
        address _lidoNFT
    ) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __ERC20_init("Staked MATIC", "StMATIC");

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(DAO, _dao);

        nodeOperator = INodeOperatorRegistry(_nodeOperator);
        stakeManager = IStakeManager(_stakeManager);
        lidoNFT = ILidoNFT(_lidoNFT);
        dao = _dao;
        token = _token;
        insurance = _insurance;

        minValidatorBalance = type(uint256).max;
        entityFees = FeeDistribution(5, 5, 90);
    }

    /**
     * @dev Send funds to LidoMatic contract and mints StMATIC to msg.sender
     * @notice Requires that msg.sender has approved _amount of MATIC to this contract
     * @param _amount - Amount of MATIC sent from msg.sender to this contract
     * @return Amount of StMATIC shares generated
     */
    function submit(uint256 _amount) external whenNotPaused returns (uint256) {
        require(_amount > 0, "Invalid amount");

        IERC20Upgradeable(token).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );

        uint256 amountToMint = convertMaticToStMatic(_amount);

        _mint(msg.sender, amountToMint);

        totalBuffered += _amount;

        emit SubmitEvent(msg.sender, _amount);

        return amountToMint;
    }

    /**
     * @dev Stores users request to withdraw into a RequestWithdraw struct
     * @param _amount - Amount of StMATIC that is requested to withdraw
     */
    function requestWithdraw(uint256 _amount) external whenNotPaused {
        Operator.OperatorInfo[] memory operatorShares = nodeOperator
            .getOperatorInfos(false);

        IERC20Upgradeable(address(this)).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );

        uint256 tokenId;
        uint256 operatorsTraverseCount;

        uint256 totalBurned;
        uint256 totalAmount2WithdrawInMatic = convertStMaticToMatic(_amount);
        uint256 currentAmount2WithdrawInMatic = totalAmount2WithdrawInMatic;
        uint256 totalDelegated = getTotalStakeAcrossAllValidators();

        lockedAmountStMatic += _amount;
        lockedAmountMatic += totalAmount2WithdrawInMatic;

        if (
            totalDelegated >= currentAmount2WithdrawInMatic &&
            operatorShares.length > 0
        ) {
            while (currentAmount2WithdrawInMatic != 0) {
                require(
                    operatorsTraverseCount < operatorShares.length,
                    "_amount > allowed"
                );
                if (lastWithdrawnValidatorId > operatorShares.length - 1) {
                    lastWithdrawnValidatorId = 0;
                }

                address validatorShare = operatorShares[
                    lastWithdrawnValidatorId
                ].validatorShare;

                uint256 validatorBalance = IValidatorShare(validatorShare)
                    .activeAmount();

                if (validatorBalance <= minValidatorBalance) {
                    operatorsTraverseCount++;
                    lastWithdrawnValidatorId++;
                    continue;
                }

                uint256 allowedAmount2Withdraw = validatorBalance -
                    minValidatorBalance;

                uint256 amount2WithdrawFromValidator = (allowedAmount2Withdraw >
                    currentAmount2WithdrawInMatic)
                    ? currentAmount2WithdrawInMatic
                    : allowedAmount2Withdraw;

                if (amount2WithdrawFromValidator == 0) {
                    lastWithdrawnValidatorId++;
                    operatorsTraverseCount++;
                    continue;
                }

                uint256 amount2Burn = (_amount * amount2WithdrawFromValidator) /
                    totalAmount2WithdrawInMatic;

                sellVoucher_new(
                    validatorShare,
                    amount2WithdrawFromValidator,
                    type(uint256).max
                );

                totalBurned += amount2Burn;

                if (
                    currentAmount2WithdrawInMatic ==
                    amount2WithdrawFromValidator
                ) {
                    amount2Burn += (_amount - totalBurned);
                }

                tokenId = lidoNFT.mint(msg.sender);

                token2WithdrawRequest[tokenId] = RequestWithdraw(
                    amount2Burn,
                    IValidatorShare(validatorShare).unbondNonces(address(this)),
                    block.timestamp,
                    validatorShare
                );

                currentAmount2WithdrawInMatic -= amount2WithdrawFromValidator;

                lastWithdrawnValidatorId++;
                operatorsTraverseCount++;
            }
        } else {
            tokenId = lidoNFT.mint(msg.sender);

            token2WithdrawRequest[tokenId] = RequestWithdraw(
                _amount,
                0,
                block.timestamp,
                address(0)
            );

            reservedFunds += currentAmount2WithdrawInMatic;
        }

        emit RequestWithdrawEvent(msg.sender, _amount);
    }

    /**
     * @notice This will be included in the cron job
     * @dev Delegates tokens to validator share contract
     */
    function delegate() external whenNotPaused {
        require(
            totalBuffered > delegationLowerBound + reservedFunds,
            "Amount to delegate lower than minimum"
        );
        Operator.OperatorInfo[] memory operatorShares = nodeOperator
            .getOperatorInfos(true);

        require(
            operatorShares.length > 0,
            "No operator shares, cannot delegate"
        );

        uint256 availableAmountToDelegate = totalBuffered - reservedFunds;
        uint256 maxDelegateLimitsSum;
        uint256 remainder;

        for (uint256 i = 0; i < operatorShares.length; i++) {
            maxDelegateLimitsSum += operatorShares[i].maxDelegateLimit;
        }

        require(maxDelegateLimitsSum > 0, "maxDelegateLimitsSum=0");

        uint256 totalToDelegatedAmount = maxDelegateLimitsSum <=
            availableAmountToDelegate
            ? maxDelegateLimitsSum
            : availableAmountToDelegate;

        IERC20Upgradeable(token).safeApprove(
            address(stakeManager),
            totalToDelegatedAmount
        );

        uint256 amountDelegated;

        for (uint256 i = 0; i < operatorShares.length; i++) {
            uint256 amountToDelegatePerOperator = (operatorShares[i]
                .maxDelegateLimit * totalToDelegatedAmount) /
                maxDelegateLimitsSum;

            buyVoucher(
                operatorShares[i].validatorShare,
                amountToDelegatePerOperator,
                0
            );

            validator2DelegatedAmount[
                operatorShares[i].validatorShare
            ] += amountToDelegatePerOperator;

            amountDelegated += amountToDelegatePerOperator;
        }

        remainder = availableAmountToDelegate - amountDelegated;
        totalBuffered = remainder + reservedFunds;

        emit DelegateEvent(amountDelegated, remainder);

        for (uint256 i = 0; i < operatorShares.length; i++) {
            uint256 minValidatorBalanceCurrent = (IValidatorShare(
                operatorShares[i].validatorShare
            ).activeAmount() * 10) / 100;

            if (
                minValidatorBalanceCurrent != 0 &&
                minValidatorBalanceCurrent < minValidatorBalance
            ) {
                minValidatorBalance = minValidatorBalanceCurrent;
            }
        }
    }

    /**
     * @dev Claims tokens from validator share and sends them to the
     * user if his request is in the userToWithdrawRequest
     * @param _tokenId - Id of the token that wants to be claimed
     */
    function claimTokens(uint256 _tokenId) external whenNotPaused {
        require(lidoNFT.isApprovedOrOwner(msg.sender, _tokenId), "Not owner");
        RequestWithdraw storage usersRequest = token2WithdrawRequest[_tokenId];

        require(
            block.timestamp >=
                usersRequest.requestTime + stakeManager.withdrawalDelay(),
            "Not able to claim yet"
        );

        lidoNFT.burn(_tokenId);

        uint256 amountToClaim = convertStMaticToMatic(
            usersRequest.amountToBurn
        );

        if (usersRequest.validatorAddress != address(0)) {
            unstakeClaimTokens_new(
                usersRequest.validatorAddress,
                usersRequest.validatorNonce
            );

            validator2DelegatedAmount[
                usersRequest.validatorAddress
            ] -= amountToClaim;
        } else {
            reservedFunds -= amountToClaim;
            totalBuffered -= amountToClaim;
        }

        uint256 amountToBurn = usersRequest.amountToBurn;

        _burn(address(this), amountToBurn);

        lockedAmountMatic -= amountToClaim;
        lockedAmountStMatic -= amountToBurn;

        IERC20Upgradeable(token).safeTransfer(msg.sender, amountToClaim);

        emit ClaimTokensEvent(
            msg.sender,
            _tokenId,
            amountToClaim,
            amountToBurn
        );
    }

    /**
     * @dev Distributes rewards claimed from validator shares based on fees defined in entityFee
     */
    function distributeRewards() external whenNotPaused {
        Operator.OperatorInfo[] memory operatorShares = nodeOperator
            .getOperatorInfos(true);

        for (uint256 i = 0; i < operatorShares.length; i++) {
            IValidatorShare(operatorShares[i].validatorShare).withdrawRewards();
        }

        uint256 totalRewards = ((IERC20Upgradeable(token).balanceOf(
            address(this)
        ) - totalBuffered) * 1) / 10;

        require(
            totalRewards > rewardDistributionLowerBound,
            "Amount to distribute lower than minimum"
        );

        uint256 balanceBeforeDistribution = IERC20Upgradeable(token).balanceOf(
            address(this)
        );

        uint256 daoRewards = (totalRewards * entityFees.dao) / 100;
        uint256 insuranceRewards = (totalRewards * entityFees.insurance) / 100;
        uint256 operatorsRewards = (totalRewards * entityFees.operators) / 100;

        IERC20Upgradeable(token).safeTransfer(dao, daoRewards);
        IERC20Upgradeable(token).safeTransfer(insurance, insuranceRewards);

        Operator.OperatorInfo[] memory operators = nodeOperator
            .getOperatorInfos(true);

        uint256[] memory ratios = new uint256[](operatorShares.length);
        uint256 totalRatio = 0;

        for (uint256 idx = 0; idx < operators.length; idx++) {
            uint256 rewardRatio = operators[idx].rewardPercentage;
            ratios[idx] = rewardRatio;
            totalRatio += rewardRatio;
        }

        for (uint256 i = 0; i < operators.length; i++) {
            IERC20Upgradeable(token).safeTransfer(
                operators[i].rewardAddress,
                (operatorsRewards * ratios[i]) / totalRatio
            );
        }

        uint256 currentBalance = IERC20Upgradeable(address(this)).balanceOf(
            address(this)
        );
        uint256 totalDistributed = balanceBeforeDistribution - currentBalance;

        // Add the remainder to totalBuffered
        totalBuffered += (currentBalance - totalBuffered);

        emit DistributeRewardsEvent(totalDistributed);
    }

    /**
     * @notice Only NodeOperator can call this function
     * @dev Withdraws funds from unstaked validator
     * @param _validatorShare - Address of the validator share that will be withdrawn
     */
    function withdrawTotalDelegated(address _validatorShare)
        external
        whenNotPaused
    {
        require(msg.sender == address(nodeOperator), "Not a node operator");

        uint256 tokenId = lidoNFT.mint(address(this));

        (uint256 stakedAmount, ) = getTotalStake(
            IValidatorShare(_validatorShare)
        );

        sellVoucher_new(_validatorShare, stakedAmount, type(uint256).max);

        token2WithdrawRequest[tokenId] = RequestWithdraw(
            uint256(0),
            IValidatorShare(_validatorShare).unbondNonces(address(this)),
            block.timestamp,
            _validatorShare
        );

        emit WithdrawTotalDelegatedEvent(_validatorShare, stakedAmount);
    }

    /**
     * @dev Claims tokens from validator share and sends them to the
     * LidoMatic contract
     * @param _tokenId - Id of the token that is supposed to be claimed
     */
    function claimTokens2LidoMatic(uint256 _tokenId) external whenNotPaused {
        RequestWithdraw storage lidoRequests = token2WithdrawRequest[_tokenId];

        require(
            lidoNFT.ownerOf(_tokenId) == address(this),
            "Not owner of the NFT"
        );

        lidoNFT.burn(_tokenId);

        require(
            block.timestamp >=
                lidoRequests.requestTime + stakeManager.withdrawalDelay(),
            "Not able to claim yet"
        );

        uint256 balanceBeforeClaim = IERC20Upgradeable(token).balanceOf(
            address(this)
        );

        unstakeClaimTokens_new(
            lidoRequests.validatorAddress,
            lidoRequests.validatorNonce
        );

        uint256 claimedAmount = IERC20Upgradeable(token).balanceOf(
            address(this)
        ) - balanceBeforeClaim;

        // Update totalBuffered after claiming the amount
        totalBuffered += claimedAmount;

        // Update delegated amount for a validator
        validator2DelegatedAmount[
            lidoRequests.validatorAddress
        ] -= claimedAmount;

        emit ClaimTokensEvent(address(this), _tokenId, claimedAmount, 0);
    }

    /**
     * @dev Flips the pause state
     */
    function togglePause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused() ? _unpause() : _pause();
    }

    ////////////////////////////////////////////////////////////
    /////                                                    ///
    /////             ***ValidatorShare API***               ///
    /////                                                    ///
    ////////////////////////////////////////////////////////////

    /**
     * @dev API for delegated buying vouchers from validatorShare
     * @param _validatorShare - Address of validatorShare contract
     * @param _amount - Amount of MATIC to use for buying vouchers
     * @param _minSharesToMint - Minimum of shares that is bought with _amount of MATIC
     * @return Actual amount of MATIC used to buy voucher, might differ from _amount because of _minSharesToMint
     */
    function buyVoucher(
        address _validatorShare,
        uint256 _amount,
        uint256 _minSharesToMint
    ) private returns (uint256) {
        uint256 amountSpent = IValidatorShare(_validatorShare).buyVoucher(
            _amount,
            _minSharesToMint
        );

        return amountSpent;
    }

    /**
     * @dev API for delegated restaking rewards to validatorShare
     * @param _validatorShare - Address of validatorShare contract
     */
    function restake(address _validatorShare) private {
        IValidatorShare(_validatorShare).restake();
    }

    /**
     * @dev API for delegated unstaking and claiming tokens from validatorShare
     * @param _validatorShare - Address of validatorShare contract
     * @param _unbondNonce - Unbond nonce
     */
    function unstakeClaimTokens_new(
        address _validatorShare,
        uint256 _unbondNonce
    ) private {
        IValidatorShare(_validatorShare).unstakeClaimTokens_new(_unbondNonce);
    }

    /**
     * @dev API for delegated selling vouchers from validatorShare
     * @param _validatorShare - Address of validatorShare contract
     * @param _claimAmount - Amount of MATIC to claim
     * @param _maximumSharesToBurn - Maximum amount of shares to burn
     */
    function sellVoucher_new(
        address _validatorShare,
        uint256 _claimAmount,
        uint256 _maximumSharesToBurn
    ) private {
        IValidatorShare(_validatorShare).sellVoucher_new(
            _claimAmount,
            _maximumSharesToBurn
        );
    }

    /**
     * @dev API for getting total stake of this contract from validatorShare
     * @param _validatorShare - Address of validatorShare contract
     * @return Total stake of this contract and MATIC -> share exchange rate
     */
    function getTotalStake(IValidatorShare _validatorShare)
        public
        view
        returns (uint256, uint256)
    {
        return _validatorShare.getTotalStake(address(this));
    }

    /**
     * @dev API for liquid rewards of this contract from validatorShare
     * @param _validatorShare - Address of validatorShare contract
     * @return Liquid rewards of this contract
     */
    function getLiquidRewards(IValidatorShare _validatorShare)
        external
        view
        returns (uint256)
    {
        return _validatorShare.getLiquidRewards(address(this));
    }

    ////////////////////////////////////////////////////////////
    /////                                                    ///
    /////            ***Helpers & Utilities***               ///
    /////                                                    ///
    ////////////////////////////////////////////////////////////

    /**
     * @dev Helper function for that returns total pooled MATIC
     * @return Total pooled MATIC
     */
    function getTotalStakeAcrossAllValidators() public view returns (uint256) {
        uint256 totalStake;

        Operator.OperatorInfo[] memory operatorShares = nodeOperator
            .getOperatorInfos(false);

        for (uint256 i = 0; i < operatorShares.length; i++) {
            (uint256 currValidatorShare, ) = getTotalStake(
                IValidatorShare(operatorShares[i].validatorShare)
            );

            totalStake += currValidatorShare;
        }

        return totalStake;
    }

    /**
     * @dev Function that calculates total pooled Matic
     * @return Total pooled Matic
     */
    function getTotalPooledMatic() public view returns (uint256) {
        uint256 totalStaked = getTotalStakeAcrossAllValidators();

        return (totalStaked + totalBuffered) - lockedAmountMatic;
    }

    /**
     * @dev Function that converts arbitrary StMatic to Matic
     * @param _balance - Balance in StMatic
     * @return Balance in Matic
     */
    function convertStMaticToMatic(uint256 _balance)
        public
        view
        returns (uint256)
    {
        uint256 totalShares = totalSupply() - lockedAmountStMatic;
        totalShares = totalShares == 0 ? 1 : totalShares;

        uint256 totalPooledMATIC = getTotalPooledMatic();
        totalPooledMATIC = totalPooledMATIC == 0 ? 1 : totalPooledMATIC;

        uint256 balanceInMATIC = (_balance * totalPooledMATIC) / totalShares;

        return balanceInMATIC;
    }

    function convertMaticToStMatic(uint256 _balance)
        public
        view
        returns (uint256)
    {
        uint256 totalShares = totalSupply() - lockedAmountStMatic;
        totalShares = totalShares == 0 ? 1 : totalShares;

        uint256 totalPooledMatic = getTotalPooledMatic();
        totalPooledMatic = totalPooledMatic == 0 ? 1 : totalPooledMatic;

        uint256 balanceInStMatic = (_balance * totalShares) / totalPooledMatic;

        return balanceInStMatic;
    }

    ////////////////////////////////////////////////////////////
    /////                                                    ///
    /////                 ***Setters***                      ///
    /////                                                    ///
    ////////////////////////////////////////////////////////////

    /**
     * @dev Function that sets entity fees
     * @notice Callable only by dao
     * @param _daoFee - DAO fee in %
     * @param _operatorsFee - Operator fees in %
     * @param _insuranceFee - Insurance fee in %
     */
    function setFees(
        uint8 _daoFee,
        uint8 _operatorsFee,
        uint8 _insuranceFee
    ) external onlyRole(DAO) {
        require(
            _daoFee + _operatorsFee + _insuranceFee == 100,
            "sum(fee)!=100"
        );
        entityFees.dao = _daoFee;
        entityFees.operators = _operatorsFee;
        entityFees.insurance = _insuranceFee;
    }

    /**
     * @dev Function that sets new dao address
     * @notice Callable only by dao
     * @param _address - New dao address
     */
    function setDaoAddress(address _address) external onlyRole(DAO) {
        dao = _address;
    }

    /**
     * @dev Function that sets new insurance address
     * @notice Callable only by dao
     * @param _address - New insurance address
     */
    function setInsuranceAddress(address _address) external onlyRole(DAO) {
        insurance = _address;
    }

    /**
     * @dev Function that sets new node operator address
     * @notice Only callable by dao
     * @param _address - New node operator address
     */
    function setNodeOperatorAddress(address _address) external onlyRole(DAO) {
        nodeOperator = INodeOperatorRegistry(_address);
    }

    /**
     * @dev Function that sets new lower bound for delegation
     * @notice Only callable by dao
     * @param _delegationLowerBound - New lower bound for delegation
     */
    function setDelegationLowerBound(uint256 _delegationLowerBound)
        external
        onlyRole(DAO)
    {
        delegationLowerBound = _delegationLowerBound;
    }

    /**
     * @dev Function that sets new lower bound for rewards distribution
     * @notice Only callable by dao
     * @param _rewardDistributionLowerBound - New lower bound for rewards distribution
     */
    function setRewardDistributionLowerBound(
        uint256 _rewardDistributionLowerBound
    ) external onlyRole(DAO) {
        rewardDistributionLowerBound = _rewardDistributionLowerBound;
    }

    /**
     * @dev Function that sets the lidoNFT address
     * @param _lidoNFT new lidoNFT address
     */
    function setLidoNFT(address _lidoNFT) external onlyRole(DAO) {
        lidoNFT = ILidoNFT(_lidoNFT);
    }

    /**
     * @dev Function that sets the new version
     * @param _version - New version that will be set
     */
    function setVersion(string calldata _version)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        version = _version;
    }
}