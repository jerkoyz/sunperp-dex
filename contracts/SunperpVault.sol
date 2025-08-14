// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./Address.sol";
import "./SafeERC20.sol";
import "./MessageHashUtils.sol";
import "./SignatureChecker.sol";
import "./PausableUpgradeable.sol";
import "./StoppableUpgradeable.sol";
import "./UUPSUpgradeable.sol";
import "./AccessControlEnumerableUpgradeable.sol";
import "./ECDSA.sol";

contract SunperpVault is PausableUpgradeable,StoppableUpgradeable,AccessControlEnumerableUpgradeable, UUPSUpgradeable {
    using Address for address payable;
    using SafeERC20 for IERC20;
    using SignatureChecker for address;
    using ECDSA for bytes32;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant BUSINESS_ROLE = keccak256("BUSINESS_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant STOP_ROLE = keccak256("STOP_ROLE");
    bytes32 public constant OPERATE_ROLE = keccak256("OPERATE_ROLE");

    address constant public NATIVE = address(bytes20(keccak256("NATIVE")));

    event UpgraderSet(address indexed upgraderBefore, address indexed upgraderAfter);
    event ReceiveETH(address indexed from, address indexed to, uint256 amount);
    event Deposit(address indexed account, address indexed currency, uint256 amount, uint256 broker);
    event WithdrawPaused(address indexed trigger, address indexed currency, uint256 amount);
    event Withdraw(uint256 indexed id, address from, address indexed to, address indexed currency, uint256 amount);
    event NewSigner(address oldSigner, address newSigner);
    event AddToken(address indexed currency, uint256 hourlyLimit, uint8 newHourlyLimit);
    event RemoveToken(address indexed currency);
    event ValidatorAdd(bytes32 indexed hash, uint validatorNum, uint totalPower);
    event ValidatorRemove(bytes32 indexed hash, uint validatorNum);
    event WhitelistSet(address indexed account, bool stateBefore, bool stateAfter);

    error ZeroAddress();
    error ZeroAmount();
    error CurrencyNotSupport(address currency);
    error ValueNotZero();

    struct Token {
        address currency;
        uint256 hourlyLimit;
        uint8 currencyDecimals;
    }

    struct ValidatorInfo {
        address signer;
        uint256 power;
    }

    struct WithdrawAction {
        address token;
        address receiver;
        uint256 amount;
        uint256 deadline;
    }

    address public upgrader;

    //uint256 public hourlyLimit;
    mapping(address => Token) public supportToken;
    // id => block.number
    mapping(uint256 => uint256) public withdrawHistory;
    // token => block.timestamp / 1 hours => amount
    mapping(address => mapping(uint256 => uint256)) public withdrawPerHours;
    mapping(bytes32 => uint) public availableValidators;
    mapping(address => bool) public whitelist;


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {
        if (msg.value > 0) {
            emit ReceiveETH(msg.sender, address(this), msg.value);
        }
    }

    modifier onlyUpgrader() {
        require(msg.sender == upgrader, "only upgrader");
        _;
    }

    function initialize(address defaultAdmin, address defaultUpgrader) initializer public {
        __Pausable_init();
        __Stoppable_init();
        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(ADMIN_ROLE, defaultAdmin);
        upgrader = defaultUpgrader;
    }

    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    function stop() external onlyRole(STOP_ROLE) {
        _stop();
    }

    function unstop() external onlyRole(ADMIN_ROLE) {
        _unstop();
    }

    function _authorizeUpgrade(address newImplementation) internal onlyUpgrader override {}

    function setUpgrader(address newUpgrader) external onlyRole(ADMIN_ROLE) {
        if (newUpgrader == address(0)) revert ZeroAddress();
        address upgraderBefore = upgrader;
        if(upgraderBefore == newUpgrader){
            return;
        }
        upgrader = newUpgrader;
        emit UpgraderSet(upgraderBefore, newUpgrader);
    }

    function addValidator(ValidatorInfo[] calldata validators) external onlyRole(ADMIN_ROLE) {
        require(validators.length > 0 && validators.length < 10, "illegal validators length");
        bytes32 validatorHash = keccak256(abi.encode(validators));
        require(availableValidators[validatorHash] == 0, "already set");
        uint totalPower = 0;
        address lastValidator = address(0);
        for (uint i = 0; i < validators.length; i ++) {
            require(validators[i].signer > lastValidator, "validator not ordered");
            totalPower += validators[i].power;
            lastValidator = validators[i].signer;
        }
        availableValidators[validatorHash] = totalPower;
        emit ValidatorAdd(validatorHash, validators.length, totalPower);
    }

    function removeValidator(ValidatorInfo[] calldata validators) external onlyRole(ADMIN_ROLE) {
        bytes32 validatorHash = keccak256(abi.encode(validators));
        require(availableValidators[validatorHash] != 0, "not set");
        delete availableValidators[validatorHash];
        emit ValidatorRemove(validatorHash, validators.length);
    }

    function setWhitelist(address account, bool state) external onlyRole(ADMIN_ROLE) {
        bool stateBefore = whitelist[account];
        if(stateBefore == state){
            return;
        }
        whitelist[account] = state;
        emit WhitelistSet(account, stateBefore, state);
    }

    function addToken(
        address currency,
        uint256 hourlyLimit,
        uint8 currencyDecimals
    ) external onlyRole(BUSINESS_ROLE) {
        if (currency == address(0)) revert ZeroAddress();
        Token storage token = supportToken[currency];
        token.currency = currency;
        token.hourlyLimit = hourlyLimit;
        token.currencyDecimals = currencyDecimals;
        emit AddToken(currency, hourlyLimit, currencyDecimals);
    }

    function removeToken(address currency) external onlyRole(BUSINESS_ROLE) {
        if (currency == address(0)) revert ZeroAddress();
        delete supportToken[currency];
        emit RemoveToken(currency);
    }

    function _transfer(address payable to, address currency, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        if (currency == NATIVE) {
            to.sendValue(amount);
        } else {
            IERC20 token = IERC20(currency);
            require(token.balanceOf(address(this)) >= amount, "not enough currency balance");
            token.safeTransfer(to, amount);
        }
    }

    function deposit(address currency, uint256 amount, uint256 broker) external payable {
        if (!_supportCurrency(currency)) revert CurrencyNotSupport(currency);
        if (currency == NATIVE) {
            //nativeToken
            amount = msg.value;
        } else {
            if (msg.value != 0) revert ValueNotZero();
            IERC20 erc20 = IERC20(currency);
            uint balanceBefore = erc20.balanceOf(address(this));
            erc20.safeTransferFrom(msg.sender, address(this), amount);
            uint balanceAfter = erc20.balanceOf(address(this));
            amount = balanceAfter - balanceBefore;
        }
        if (amount == 0) revert ZeroAmount();
        emit Deposit(msg.sender, currency, amount, broker);
    }

    function withdrawWhitelist(uint256 id, ValidatorInfo[] calldata validators, WithdrawAction calldata action, bytes[] calldata validatorSignatures) external whenNotPaused whenNotStopped onlyRole(OPERATE_ROLE) {
        require(_supportCurrency(action.token), "currency not support");
        require(whitelist[action.receiver], "addresses not support");
        _withdraw(id, validators, action, validatorSignatures);
    }

    function withdraw(uint256 id, ValidatorInfo[] calldata validators, WithdrawAction calldata action, bytes[] calldata validatorSignatures) external whenNotPaused whenNotStopped onlyRole(OPERATE_ROLE) {
        require(_supportCurrency(action.token), "currency not support");
        if (!checkLimit(action.token, action.amount)) {
            return;
        }

        _withdraw(id, validators, action, validatorSignatures);
    }

    function _withdraw(uint256 id, ValidatorInfo[] calldata validators, WithdrawAction calldata action, bytes[] calldata validatorSignatures) internal {
        require(block.timestamp < action.deadline, "already passed deadline");
        require(withdrawHistory[id] == 0, "already withdraw");
        bytes32 digest = keccak256(abi.encode(
            id,
            block.chainid,
            address(this),
            action.token,
            action.receiver,
            action.amount,
            action.deadline
        ));
        verifyValidatorSignature(validators, digest, validatorSignatures);
        withdrawHistory[id] = block.number;
        _transfer(payable(action.receiver), action.token, action.amount);
        emit Withdraw(id, msg.sender, action.receiver, action.token, action.amount);
    }

    function _supportCurrency(address currency) private view returns (bool) {
        return supportToken[currency].currency != address(0);
    }

    function balance(address currency) external view returns (uint256) {
        if (currency == NATIVE) {
            return address(this).balance;
        } else {
            return IERC20(currency).balanceOf(address(this));
        }
    }

    function verifyValidatorSignature(ValidatorInfo[] calldata validators, bytes32 digest, bytes[] calldata validatorSignatures) internal view {
        bytes32 validatorHash = keccak256(abi.encode(validators));
        uint totalPower = availableValidators[validatorHash];
        require(totalPower > 0, "validator illegal");
        uint power = 0;
        uint validatorIndex = 0;
        bytes32 validatorDigest = MessageHashUtils.toEthSignedMessageHash(digest);
        for (uint i = 0; i < validatorSignatures.length && validatorIndex < validators.length; i ++) {
            address recover = validatorDigest.recover(validatorSignatures[i]);
            if (recover == address(0)) {
                continue;
            }
            while (validatorIndex < validators.length) {
                address validator = validators[validatorIndex].signer;
                validatorIndex ++;
                if (validator == recover) {
                    power += validators[validatorIndex - 1].power;
                    break;
                }
            }
        }
        require(power >= totalPower * 3 / 3, "validator signature illegal");
    }

    function checkLimit(address currency, uint256 amount) internal returns(bool) {
        Token memory token = supportToken[currency];
        uint256 cursor = block.timestamp / 1 hours;
        if (withdrawPerHours[currency][cursor] + amount > token.hourlyLimit * (10 ** token.currencyDecimals)) {
            _pause();
            emit WithdrawPaused(msg.sender, currency, amount);
            return false;
        } else {
            withdrawPerHours[currency][cursor] += amount;
            return true;
        }
    }
}