// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {ICurveFi} from "../interfaces/curve/ICurveFi.sol";
import {IUniswapV2Router02} from "../interfaces/uniswap/IUniswapV2Router.sol";
import {StrategyProxy} from "../interfaces/yearn/StrategyProxy.sol";

// These are the core Yearn libraries
import {
    BaseStrategy
} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";


// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

/*
    @title Generic Strategy for Curve Pool
    @author Yearn.finance
    @notice This contract is intended to be as generic as possible, allowing quick deployments for new Curve-based strategies
*/

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    string public name;
    bool public usesEth;

    // Tokens
    IERC20[] public poolTokens;
    IERC20[] public rewardsTokens;
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Dex variables
    mapping(address => address) public routers;

    struct SellPath {
        uint16 numOfShares;
        bool exists;
    }

    mapping(address => address[]) public sellPaths;

    // Curve contract
    address public gauge;
    ICurveFi public curveSwap;
    address public harvestForToken;

    StrategyProxy public proxy = StrategyProxy(address(0x9a3a03C614dc467ACC3e81275468e033c98d960E));    

    /**
        @notice Contract constructor
        @param _vault, vault to attach strategy to
        @param _name, name of this contract
        @param _gauge, Curve gauge that this strategy should connect to
        @param _curveSwap, Curve contract where we add/remove liquidity to/from
        @param _harvestForToken, Token which should be purchased and re-invested during harvest
        @param _rewardsTokens, Array of 0-n rewards tokens (non-CRV) associated with this pool
        @param _rewardsRouters, Array of best-price AMM routers for swapping each reward token against. Index should match rewardsTokens index.
        @param _usesEth, if this contract should interact with ETH. If not, make not payable.
    */
    constructor(
        address _vault,
        string _name,
        address _gauge, 
        address _curveSwap, 
        address _harvestForToken, 
        address[] _rewardsTokens, 
        address[] _rewardsRouters,
        bool _usesEth)
    public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 43200;
        profitFactor = 2000;
        debtThreshold = 400*1e18;
        rewardsTokens[_rewardsTokens.length];
        gauge = _gauge;
        curveSwap = ICurveFi(address(_curveSwap));
        harvestForToken = _harvestForToken;
        // Add all rewards tokens to an array of ERC20s - we assume they are ERC20 compatible
        for (uint i = 0; i < _poolTokens.length; i++) {
            poolTokens.push(IERC20(_poolTokens[i]));
        }

        // Add all rewards tokens to an array of ERC20s and give them preferred DEX routers - we assume they are ERC20 compatible
        if(_rewardsTokens.length > 0){
            rewardsTokens = new IERC20[](_rewardsTokens.length);
            for (uint i = 0; i < _rewardsTokens.length; i++) {
                require(_rewardsTokens.length == _rewardsRouters.length, "Reward token array and router size must match");
                IERC20 token = IERC20(_rewardsTokens[i]);
                rewardsTokens.push(token);
                // Set router
                routers[address(token)] = _rewardsRouters[i];
                token.safeApprove(routers[token], uint256(-1));
                sellPaths[address(token)] = new address[](2);
                sellPaths[address(token)][0] = address(token);
                sellPaths[address(token)][1] = harvestForToken;
            }
        }

        want.safeApprove(address(proxy), uint256(-1));
        IERC20(harvestForToken).approve(address(CurveStableSwap), uint256(-1));
        usesEth = _usesEth;
    }

    /**
        @notice accept ETH only if this Curve pool interacts with it 
    */
    receive() external payable {
        require(usesEth, "ETH not accepted");
    }

    /**
        @notice name of smart contract
        @return name of smart contract  
    */
    function name() external override view returns (string memory) {
        return name;
    }

    function estimatedTotalAssets() public override view returns (uint256) {
        return proxy.balanceOf(gauge);
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment) {
        uint256 gaugeTokens = proxy.balanceOf(gauge);

        if(gaugeTokens > 0){
            proxy.harvest(gauge);

            uint256[] rewardsBalances = new uint256[](rewardsTokens.length);

            // If this pool offers rewards tokens, claim them, and then sell them only if a balance is > 0
            for (uint i = 0; i < rewardsTokens.length; i++) {
                proxy.claimRewards(gauge, address(rewardsTokens[i]));
                rewardsBalances[i] = rewardsTokens[i].balanceOf(address(this));
                if(rewardsBalances[i] > 0){
                    _sell(address(rewardsTokens[i]), rewardsBalances[i]);
                }
            }

            // Invest balances back into want
            uint256 balance = IERC20(harvestForToken).balanceOf(address(this));
            if(balance > 0){
                CurveStableSwap.add_liquidity{value: eth_balance}([eth_balance, 0], 0);
            }
            _profit = want.balanceOf(address(this));
        }

        if(_debtOutstanding > 0){
            if(_debtOutstanding > _profit){
                uint256 stakedBal = proxy.balanceOf(gauge);
                proxy.withdraw(gauge, address(want), Math.min(stakedBal,_debtOutstanding - _profit));
            }
            _debtPayment = Math.min(_debtOutstanding, want.balanceOf(address(this)).sub(_profit));
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _toInvest = want.balanceOf(address(this));
        want.safeTransfer(address(proxy), _toInvest);
        proxy.deposit(gauge, address(want));
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        uint256 wantBal = want.balanceOf(address(this));
        uint256 stakedBal = proxy.balanceOf(gauge);

        if(_amountNeeded > wantBal){
            proxy.withdraw(gauge, address(want), Math.min(stakedBal, _amountNeeded - wantBal));
        }
        _liquidatedAmount = Math.min(_amountNeeded, want.balanceOf(address(this)));

    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function prepareMigration(address _newStrategy) internal override {
        // Because this strategy utilizes the proxy, gauge tokens will remain in the voter contract even after migration: We don't need to move them.
        prepareReturn(proxy.balanceOf(gauge));
    }

    /**
        @notice This funciton sells a specified token and amount
        @param token, token to sell 
        @param amount, amount of token to sell
    */
    function _sell(address token, uint256 amount) internal {
        if(usesEth){
            IUniswapV2Router02(routers[address(token)]).swapExactTokensForETH(amount, uint256(0), crvPath, address(this), now);
        }
        else
            IUniswapV2Router02(routers[address(ANKR)]).swapExactTokensForTokens(amount, uint256(0), ankrPath, address(this), now);
        }
    }

    function setDex(address _token, address _newDex) public onlyGovernance {
        routers[_token] = _newDex;
    }

    function setProxy(address _proxy) public onlyGovernance {
        proxy = StrategyProxy(_proxy);
    }

    function protectedTokens() internal override view returns (address[] memory) {
        address[] memory protected = new address[](1);
          protected[0] = address(gauge);
          return protected;
    }
}
