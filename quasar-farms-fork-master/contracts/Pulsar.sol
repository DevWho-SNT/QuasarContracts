// SPDX-License-Identifier: MIT
// Version 0.99

pragma solidity ^0.8.4;
pragma experimental ABIEncoderV2;

import "./deps/libs/SafeMath.sol";
import "./deps/libs/IERC20.sol";
import "./deps/libs/IERC721.sol";
import "./deps/libs/SafeERC20.sol";

import "./deps/libs/Address.sol";
import "./QuasarAccessControls.sol";
import "./deps/libs/Arrays.sol";
import "./deps/ReentrancyGuard.sol";


import "./QuasarToken.sol";
import "./Starburst.sol";

/*
    *   Pulsar is a natural phenomenon. Its a neutron star emitting electromagnetic
    *   radiation from its poles.
    *
    *   Pulsar it's a fork/fusion of NeutronStar and Masterdemon.sol (kuddos to lawrence_of_arabia & kisile, source below [1])
    *   Made by the OFO Team for QuasarSwap.
    *
    *                 Have fun reading it. Hopefully it's bug-free. God bless.
*/


/*
*
*   Information for devs
*   qsrPerBlock 0250000000000000000   = 0.25 QSR per block
*   fees  1,000,000,000,000,000,000 = 1 eth
*            10,000,000,000,000,000 = 0.01 eth
*             1,000,000,000,000,000 = 0.001 eth
*               100,000,000,000,000 = 0.0001 eth
*/

// TO DO
interface IMigratorChef {
    function migrate(IERC20 token) external returns (IERC20);
}

contract Pulsar is ReentrancyGuard {
    QuasarAccessControls public accessControls;
    using Address for address;
    using Arrays for uint256[];
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        mapping(address => uint256[]) stakedTokens;  // Keep track of each user and their info
        uint256 amountStaked;
        uint256 rewardDebt; // Reward debt. See explanation below.
      
        /*
        * We do some fancy math here. Basically, any point in time, the amount of QSRs
        * entitled to a user but is pending to be distributed is:
        *
        *   pending reward = (user.amount * pool.accQsrPerShare) - user.rewardDebt
        *
        * Whenever a user deposits or withdraws NFTs to a collection. Here's what happens:
        *   1. The collection's `accQsrPerShare` (and `lastRewardBlock`) gets updated.
        *   2. User receives the pending reward sent to his/her address.
        *   3. User's `amountStaked` gets updated.
        *   4. User's `rewardDebt` gets updated.
        */
    }

    // Info of each collection.
    struct CollectionInfo {
        bool isStakable;
        address collectionAddress;
        uint256 stakingFee;
        uint256 harvestingFee;
        uint256 amountOfStakers;
        uint256 stakingLimit;
        uint256 allocPoint;       // How many allocation points assigned to this pool. QSRs to distribute per block.
        uint256 accQsrPerShare; // Accumulated QSRs per share, times 1e12. See below.
        uint256 lastRewardBlock;  // Last block number that QSRs distribution occurs.
    }

    // The QSR token
    QuasarToken public qsr;
    // The SBR token
    Starburst public sbr;
    // Dev address.
    address public devaddr;
    // QSR tokens created per block.
    uint256 public qsrPerBlock;
    // Bonus muliplier for early qsr makers.
    uint256 public BONUS_MULTIPLIER = 1;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Map user addresses over their info
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Collection address => (staked nft => user address)
    mapping(address => mapping(uint256 => address)) public tokenOwners;
    // Total NFTs staked by all users
    // Collection address => total NFT staked
    mapping(address => uint256) public totalStakedByCollection;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when QSR mining starts.
    uint256 public startBlock;

    // Info of each pool.
    CollectionInfo[] public collectionInfo;

    event Deposit(address indexed user, uint256 indexed cid, uint256 nid);
    event Withdraw(address indexed user, uint256 indexed cid, uint256 nid);
    event EmergencyWithdraw(address indexed user, uint256 indexed cid, uint256 nid);

    constructor(
        QuasarToken _qsr,
        Starburst _sbr,
        address _devaddr,
        uint256 _qsrPerBlock,
        uint256 _startBlock,
        QuasarAccessControls _accessControls
    ) {
        qsr = _qsr;
        sbr = _sbr;
        devaddr = _devaddr;
        qsrPerBlock = _qsrPerBlock;
        startBlock = _startBlock;
        accessControls = _accessControls;
    }

    /*-------------------------------Admin functions-------------------------------*/
   
    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(
        IMigratorChef _migrator
    ) public {
        require(
            accessControls.hasAdminRole(msg.sender),
            "Pulsar: Sender must have admin permissions"
        );
        migrator = _migrator;
    }

    function updateMultiplier(
        uint256 multiplierNumber
    ) public {
        require(
            accessControls.hasAdminRole(msg.sender),
            "Pulsar: Sender must have admin permissions"
        );
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function collectionInfoLength(
    ) external 
    view 
    returns (uint256) {
        return collectionInfo.length;
    }

    function setQsrPerBlock(
        uint256 _qsrPerBlock
    ) external {
        /*
         This MUST be done or pool rewards will 
         be calculated with new qsr per second
         This could unfairly punish small collections that don't 
         have frequent deposits/withdraws/harvests
        */
        require(
            accessControls.hasAdminRole(msg.sender),
            "Pulsar: Sender must have admin permissions"
        );
        massUpdatePools();

        qsrPerBlock = _qsrPerBlock;
    }

    // Add a new collection to Pulsar. Can only be called by the owner.
    function addCollection(
        bool _isStakable,
        address _collectionAddress,
        uint256 _stakingFee,
        uint256 _harvestingFee,
        uint256 _stakingLimit,
        uint256 _allocPoint
    ) public {
        require(
            accessControls.hasAdminRole(msg.sender),
            "Pulsar: Sender must have admin permissions"
        );

        checkForDuplicate(_collectionAddress); // ensure you can't add duplicate collections
        massUpdatePools();

        uint256 _lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        collectionInfo.push(
            CollectionInfo({
                isStakable: _isStakable,
                collectionAddress: _collectionAddress,
                stakingFee: _stakingFee,
                harvestingFee: _harvestingFee,
                amountOfStakers: 0,
                stakingLimit: _stakingLimit,
                allocPoint: _allocPoint,
                accQsrPerShare: 0,
                lastRewardBlock: _lastRewardBlock
            })
        );
        updateStakingPool();
    }

    // Update the given collection's data. Can only be called by the owner.
    function updateCollection(
        uint256 _cid,
        bool _isStakable,
        address _collectionAddress,
        uint256 _stakingFee,
        uint256 _harvestingFee,
        uint256 _stakingLimit,
        uint256 _allocPoint
    ) public {
        require(
            accessControls.hasAdminRole(msg.sender),
            "Pulsar: Sender must have admin permissions"
        );

        CollectionInfo storage collection = collectionInfo[_cid];
        
        collection.isStakable = _isStakable;
        collection.collectionAddress = _collectionAddress;
        collection.stakingFee = _stakingFee;
        collection.harvestingFee = _harvestingFee;
        collection.stakingLimit = _stakingLimit;
        massUpdatePools();

        uint256 prevAllocPoint = collectionInfo[_cid].allocPoint;
        collectionInfo[_cid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }
    }

    // Update dev address by the previous dev.
    function setDev(
        address _devaddr
    ) public {
        require(
            msg.sender == devaddr, 
            "dev: wut?"
        );
        devaddr = _devaddr;
    }

    /**
    *   Withdraw SNT from contract
    */

    function withdraw() external  {
        require(
            accessControls.hasAdminRole(msg.sender),
            "Pulsar: Sender must have admin permissions"
        );
        payable(msg.sender).transfer(address(this).balance);
    }

    /*-------------------------------Helper functions-------------------------------*/

    function checkForDuplicate(
        address _collectionAddress
    ) internal 
      view {
        uint256 length = collectionInfo.length;
        for (uint256 _cid = 0; _cid < length; _cid++) {
            require(
                collectionInfo[_cid].collectionAddress != _collectionAddress,
                "add: Collection already exists!"
                );
        }
    }

    function updateStakingPool() 
    internal {
        uint256 length = collectionInfo.length;
        uint256 points = 0;
        for (uint256 cid = 1; cid < length; ++cid) {
            points = points.add(collectionInfo[cid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(collectionInfo[0].allocPoint).add(points);
            collectionInfo[0].allocPoint = points;
        }
    }

/*
    // Migrate NFTs to another NFT contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _cid) public {
        require(
            address(migrator) != address(0), 
            "migrate: no migrator"
        );
        
        CollectionInfo storage collection = collectionInfo[_cid];
        address collectionAddress = collection.collectionAddress;
        uint256 bal = collectionAddress.balanceOf(address(this)); //this line is not working
        collectionAddress.approve(address(migrator), bal);
        newLpToken = migrator.migrate(collectionAddress);
        require(
            bal == newLpToken.balanceOf(address(this)),
             "migrate: bad"
        );
        
        collection.collectionAddress = newLpToken;
    }

*/

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(
        uint256 _from, uint256 _to
    ) public 
      view 
      returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = collectionInfo.length;
        for (uint256 cid = 0; cid < length; ++cid) {
            updatePool(cid);
        }
    }


    // Update reward variables of the given pool to be up-to-date.
    function updatePool(
        uint256 _cid
    ) public {
        CollectionInfo storage collection = collectionInfo[_cid];
        if (block.number <= collection.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = IERC721(collection.collectionAddress).balanceOf(address(this));
        if (lpSupply == 0) {
            collection.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(collection.lastRewardBlock, block.number);
        uint256 qsrReward = multiplier.mul(qsrPerBlock).mul(collection.allocPoint).div(totalAllocPoint);
        qsr.mint(devaddr, qsrReward.div(10));
        qsr.mint(address(sbr), qsrReward);
        collection.accQsrPerShare = collection.accQsrPerShare.add(qsrReward.mul(1e12).div(lpSupply));
        collection.lastRewardBlock = block.number;
    }

    // Safe qsr transfer function, just in case if rounding error causes pool to not have enough QSRs.
    function safeQsrTransfer(
        address _to, 
        uint256 _amount
    ) internal {
        sbr.safeQsrTransfer(_to, _amount);
    }

    /*-------------------------------Main external functions-------------------------------*/

 // View function to see pending QSRs on frontend.
    function pendingQsr(
        uint256 _cid, 
        address _user
    )   external 
        view 
        returns (uint256) {

        CollectionInfo storage pool = collectionInfo[_cid];
        UserInfo storage user = userInfo[_cid][_user];

        uint256 accQsrPerShare = pool.accQsrPerShare;
        uint256 nftSupply = IERC721(pool.collectionAddress).balanceOf(address(this));

        if (block.number > pool.lastRewardBlock && nftSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 qsrReward = multiplier.mul(qsrPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accQsrPerShare = accQsrPerShare.add(qsrReward.mul(1e12).div(nftSupply));
        }
        return user.amountStaked.mul(accQsrPerShare).div(1e12).sub(user.rewardDebt);
    }

    function stake(
        uint256 _cid, 
        uint256 _nid 
    ) external payable nonReentrant {
            
        require(
            msg.value >= collectionInfo[_cid].stakingFee,
            "Pulsar.stake: Fee"
        );

        _stake(_cid, _nid, msg.sender);
    }

    function unstake(
        uint256 _cid, 
        uint256 _nid 
    ) external payable nonReentrant {
            
        require(
            msg.value >= collectionInfo[_cid].harvestingFee,
            "Pulsar.stake: Fee"
        );

        _unstake(_cid, _nid, msg.sender);
    }

    function harvest(
        uint256 _cid
    ) external payable nonReentrant {
        CollectionInfo storage collection = collectionInfo[_cid];
        UserInfo storage user = userInfo[_cid][msg.sender];  

        require(
            msg.value >= collectionInfo[_cid].harvestingFee,
            "Pulsar.stake: Fee"
        );

        updatePool(_cid);
        if (user.amountStaked > 0) {
            uint256 pending = user.amountStaked.mul(collection.accQsrPerShare).div(1e12).sub(user.rewardDebt);
                if(pending > 0) {
                    safeQsrTransfer(msg.sender, pending);
                }
        }
        user.rewardDebt = user.amountStaked.mul(collection.accQsrPerShare).div(1e12);
    }


    /*
    *    Batch functions 
    */

    function batchStake(
        uint256 _cid, 
        uint256[] memory _nids
    ) external payable nonReentrant {
        
        require(
                msg.value >= collectionInfo[_cid].stakingFee * _nids.length,
                "Pulsar.batchStake: Fee"
            );

        for (uint256 i = 0; i < _nids.length; ++i) {
            _stake(_cid, _nids[i], msg.sender);
        }
    }

    function batchUnstake(
        uint256 _cid, 
        uint256[] memory _nids
    ) external payable nonReentrant {
        require(
                msg.value >= collectionInfo[_cid].harvestingFee * _nids.length,
                "Pulsar.batchUnstake: Fee"
        );

        for (uint256 i = 0; i < _nids.length; ++i) {
            _unstake(_cid, _nids[i], msg.sender);
        }
    }

    function emergencyWithdraw(uint256 _cid) public nonReentrant {
        CollectionInfo storage collection = collectionInfo[_cid];
        UserInfo storage user = userInfo[_cid][msg.sender]; 

        while (user.stakedTokens[collection.collectionAddress].length > 0) {
            _emergWithdraw(_cid, msg.sender);
        }

        user.rewardDebt = 0;
    }

    /*-------------------------------Main internal functions-------------------------------*/

    /*
    * Deposit NFTs in Pulsar.
    * @param _cid => collection id
    * @param _nid => nft id
    * @param _user pretty self explanatory
    */

    function _stake(
        uint256 _cid, 
        uint256 _nid, 
        address _user
    ) internal {

        CollectionInfo storage collection = collectionInfo[_cid];
        UserInfo storage user = userInfo[_cid][_user];

        address nftOwner = IERC721(collection.collectionAddress).ownerOf(_nid);

        require(
            _user == nftOwner,
            "Pulsar.stake: NFT doesn't belong to you"
        );

        require(
            collectionInfo[_cid].isStakable == true,
            "Pulsar.stake: Staking isn't available in given pool"
        );

        require(
            user.stakedTokens[collection.collectionAddress].length <
                collection.stakingLimit,
            "Pulsar._stake: You can't stake more"
        );

        updatePool(_cid);
        if (user.amountStaked > 0) {
        uint256 pending = user.amountStaked.mul(collection.accQsrPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeQsrTransfer(msg.sender, pending);
            }
        }
            
        if (user.stakedTokens[collection.collectionAddress].length == 0) {
            collection.amountOfStakers += 1;
        }

        IERC721(collection.collectionAddress).transferFrom(
            _user, address(this), _nid);

        totalStakedByCollection[collection.collectionAddress] += 1;
        user.amountStaked += 1;

        user.stakedTokens[collection.collectionAddress].push(_nid);
        tokenOwners[collection.collectionAddress][_nid] = _user;

        user.rewardDebt = user.amountStaked.mul(collection.accQsrPerShare).div(1e12);
        emit Deposit(_user, _cid, _nid);
    }

    /*
    * Withdraw NFTs from Pulsar.
    * @param _cid => collection id
    * @param _nid => nft id
    * @param _user pretty self explanatory
    */

    function _unstake(
        uint256 _cid, 
        uint256 _nid, 
        address _user
        ) internal {

        CollectionInfo storage collection = collectionInfo[_cid];
        UserInfo storage user = userInfo[_cid][_user];

        require(
            tokenOwners[collection.collectionAddress][_nid] == _user && _user == msg.sender,
            "Pulsar.unstake: _user doesn't owns this token"
        );

        updatePool(_cid);

        uint256 pending = user.amountStaked.mul(collection.accQsrPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeQsrTransfer(_user, pending);
        }

        user.stakedTokens[collection.collectionAddress].removeElement(_nid);

        if (user.stakedTokens[collection.collectionAddress].length == 0) {
            collection.amountOfStakers -= 1;
        }

        delete tokenOwners[collection.collectionAddress][_nid];

        totalStakedByCollection[collection.collectionAddress] -= 1;
        user.amountStaked -= 1;
        if (user.amountStaked == 0) {
            delete userInfo[_cid][_user];
        }

        IERC721(collection.collectionAddress).transferFrom(
            address(this),
            _user,
            _nid
        );

        user.rewardDebt = user.amountStaked.mul(collection.accQsrPerShare).div(1e12);
        emit Withdraw(_user, _cid, _nid);
    }

    function _emergWithdraw(uint _cid, address _user) internal {
        CollectionInfo storage collection = collectionInfo[_cid];
        UserInfo storage user = userInfo[_cid][_user]; 

        uint256[] memory iteratedNFTs = user.stakedTokens[collection.collectionAddress];

        for (uint256 i = 0; i < user.stakedTokens[collection.collectionAddress].length; ++i) {
            /*
            * This function:
            * 1 Checks the entire array of staked NFTs of the user
            * 2 Checks if the caller is actually the owner of the NFT
            * 3 Sends it back, without caring about rewards
            *           Hopefully it will be useful only for testing
            *                   God bless
            */
            uint256 _nid = iteratedNFTs[i]; // token id to withdraw, the last one

            require(
                tokenOwners[collection.collectionAddress][_nid] == _user,
                "Pulsar.withdraw: Sender doesn't owns these tokens"
             );

            IERC721(collection.collectionAddress).transferFrom(
                address(this),
                _user,
                _nid
            );
            user.stakedTokens[collection.collectionAddress].removeElement(_nid);
            if (user.stakedTokens[collection.collectionAddress].length == 0) {
                collection.amountOfStakers -= 1;
            }
            delete tokenOwners[collection.collectionAddress][_nid];
            
            user.amountStaked -= 1;
            

            emit EmergencyWithdraw(_user, _cid, _nid);
        }
    }

     /*-------------------------------Get functions for frontend-------------------------------*/


    function getStakedId(
        address _user, 
        uint256 _cid
    ) public 
      view 
      returns(
        uint256[] memory
      ) 
    {
        CollectionInfo storage collection = collectionInfo[_cid];
        UserInfo storage user = userInfo[_cid][_user]; 
        uint256[] memory _nids = user.stakedTokens[collection.collectionAddress];

        return(
            _nids
        );
    }

    function getCollectionInfo(uint256 _cid)
        public
        view
        returns (
            bool,
            address,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        CollectionInfo memory collection = collectionInfo[_cid];
        return (
            collection.isStakable,
            collection.collectionAddress,
            collection.stakingFee,
            collection.harvestingFee,
            collection.amountOfStakers,
            collection.stakingLimit,
            totalStakedByCollection[collection.collectionAddress]
        );
    }

    /*-------------------------------Misc-------------------------------*/
    receive() external payable {}
}


// [1] Masterdemon.sol https://github.com/Cryptodemonz-Github/cdz-staking/blob/dev/contracts/Masterdemon.sol
// checked at commit 960cf09 