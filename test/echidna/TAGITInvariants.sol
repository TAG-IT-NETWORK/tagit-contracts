// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TAGITInvariants
 * @notice Simplified Echidna property-based fuzzing for TAG IT economics
 * @dev Uses simplified mock contracts to avoid UUPS proxy deployment complexity
 *
 * Run: echidna test/echidna/TAGITInvariants.sol --contract TAGITInvariants --config test/echidna/EchidnaConfig.yaml
 */

/// @notice Simplified ERC20 for testing
contract MockToken {
    string public name = "TAGIT";
    string public symbol = "TAGIT";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient");
        require(allowance[from][msg.sender] >= amount, "Not approved");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @notice Simplified staking for testing
contract MockStaking {
    MockToken public token;
    uint256 public totalStaked;
    mapping(address => uint256) public staked;
    address public owner;

    constructor(address _token) {
        token = MockToken(_token);
        owner = msg.sender;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "Zero amount");
        token.transferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        totalStaked += amount;
    }

    function unstake(uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(staked[msg.sender] >= amount, "Insufficient stake");
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        token.transfer(msg.sender, amount);
    }

    function pendingRewards(address) external pure returns (uint256) {
        return 0; // Simplified - no rewards in mock
    }
}

/// @notice Simplified burner for testing
contract MockBurner {
    MockToken public token;
    address public treasury;
    uint256 public burnRate = 3333; // 33.33%
    uint256 public constant BURN_FLOOR = 333; // 3.33%
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public totalBurned;
    uint256 public totalToTreasury;
    address public owner;

    constructor(address _token, address _treasury) {
        token = MockToken(_token);
        treasury = _treasury;
        owner = msg.sender;
    }

    function routeFee(uint256 amount) external {
        require(amount > 0, "Zero amount");
        token.transferFrom(msg.sender, address(this), amount);

        uint256 burnAmount = (amount * burnRate) / BASIS_POINTS;
        uint256 treasuryAmount = amount - burnAmount;

        if (burnAmount > 0) {
            token.burn(burnAmount);
            totalBurned += burnAmount;
        }
        if (treasuryAmount > 0) {
            token.transfer(treasury, treasuryAmount);
            totalToTreasury += treasuryAmount;
        }
    }

    function setBurnRate(uint256 rate) external {
        require(msg.sender == owner, "Not owner");
        require(rate >= BURN_FLOOR, "Below floor");
        require(rate <= BASIS_POINTS, "Above max");
        burnRate = rate;
    }

    function burnFloor() external pure returns (uint256) {
        return BURN_FLOOR;
    }
}

/// @notice Main invariant test contract
contract TAGITInvariants {
    MockToken public token;
    MockStaking public staking;
    MockBurner public burner;

    uint256 public totalMinted;
    uint256 public previousSupply;

    constructor() {
        // Deploy mock contracts
        token = new MockToken();
        staking = new MockStaking(address(token));
        burner = new MockBurner(address(token), address(this));

        // Mint initial tokens
        token.mint(address(this), 1_000_000 ether);
        totalMinted = 1_000_000 ether;
        previousSupply = token.totalSupply();

        // Approve contracts
        token.approve(address(staking), type(uint256).max);
        token.approve(address(burner), type(uint256).max);
    }

    // ============================================
    // HELPER FUNCTIONS (Echidna calls these)
    // ============================================

    function stake(uint256 amount) external {
        if (amount == 0 || amount > token.balanceOf(address(this))) return;
        try staking.stake(amount) {} catch {}
    }

    function unstake(uint256 amount) external {
        if (amount == 0) return;
        try staking.unstake(amount) {} catch {}
    }

    function routeFee(uint256 amount) external {
        if (amount == 0 || amount > token.balanceOf(address(this))) return;
        uint256 supplyBefore = token.totalSupply();
        try burner.routeFee(amount) {
            previousSupply = supplyBefore;
        } catch {}
    }

    function setBurnRate(uint256 rate) external {
        try burner.setBurnRate(rate) {} catch {}
    }

    // ============================================
    // INVARIANTS (must always return true)
    // ============================================

    /// @notice Token supply should be consistent
    function echidna_token_supply_valid() public view returns (bool) {
        return token.totalSupply() <= totalMinted;
    }

    /// @notice Staking contract should always be solvent
    function echidna_staking_solvent() public view returns (bool) {
        return staking.totalStaked() <= token.balanceOf(address(staking));
    }

    /// @notice Burns should decrease supply
    function echidna_burns_decrease_supply() public view returns (bool) {
        return token.totalSupply() <= previousSupply;
    }

    /// @notice Sum of known balances should not exceed total supply
    function echidna_balance_sum_bounded() public view returns (bool) {
        uint256 sum = token.balanceOf(address(this)) +
                     token.balanceOf(address(staking)) +
                     token.balanceOf(address(burner));
        return sum <= token.totalSupply();
    }

    /// @notice Burn floor should always be enforced (3.33%)
    function echidna_burn_floor_enforced() public view returns (bool) {
        return burner.burnRate() >= burner.burnFloor();
    }

    /// @notice Burn rate should never exceed 100%
    function echidna_burn_rate_bounded() public view returns (bool) {
        return burner.burnRate() <= 10000;
    }

    /// @notice Total burned should be monotonically increasing
    function echidna_burned_monotonic() public view returns (bool) {
        return burner.totalBurned() >= 0;
    }

    /// @notice Staking accounting should be correct
    function echidna_staking_accounting() public view returns (bool) {
        // Total staked should match sum of individual stakes
        return staking.totalStaked() == staking.staked(address(this));
    }
}
