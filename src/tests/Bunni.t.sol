// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";

import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {Bunni} from "../Bunni.sol";
import {SwapRouter} from "./lib/SwapRouter.sol";
import {IBunni} from "../interfaces/IBunni.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {WETH9Mock} from "./mocks/WETH9Mock.sol";
import {BunniFactory} from "../BunniFactory.sol";
import {IBunniFactory} from "../interfaces/IBunniFactory.sol";
import {UniswapDeployer} from "./lib/UniswapDeployer.sol";

contract BunniTest is Test, UniswapDeployer {
    uint256 constant PRECISION = 10**18;
    uint8 constant DECIMALS = 18;
    uint256 constant PROTOCOL_FEE = 5e17;
    uint256 constant EPSILON = 10**13;

    IUniswapV3Factory factory;
    IUniswapV3Pool pool;
    SwapRouter router;
    ERC20Mock token0;
    ERC20Mock token1;
    WETH9Mock weth;
    IBunniFactory bunniFactory;
    IBunni bunni;
    uint24 fee;

    function setUp() public {
        // initialize uniswap
        token0 = new ERC20Mock();
        token1 = new ERC20Mock();
        if (address(token0) >= address(token1)) {
            (token0, token1) = (token1, token0);
        }
        factory = IUniswapV3Factory(deployUniswapV3Factory());
        fee = 500;
        pool = IUniswapV3Pool(
            factory.createPool(address(token0), address(token1), fee)
        );
        pool.initialize(TickMath.getSqrtRatioAtTick(0));
        weth = new WETH9Mock();
        router = new SwapRouter(address(factory), address(weth));

        // initialize bunni factory
        bunniFactory = new BunniFactory(address(weth), PROTOCOL_FEE);

        // initialize bunni
        bunni = bunniFactory.createBunni(
            "Bunni LP",
            "BUNNI-LP",
            pool,
            -10000,
            10000
        );

        // approve tokens
        token0.approve(address(bunni), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(bunni), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    function test_createBunni() public {
        bunniFactory.createBunni("Bunni LP", "BUNNI-LP", pool, -10, 10);
    }

    function test_deposit() public {
        // make deposit
        uint256 depositAmount0 = PRECISION;
        uint256 depositAmount1 = PRECISION;
        (
            uint256 shares,
            uint128 newLiquidity,
            uint256 amount0,
            uint256 amount1
        ) = _makeDeposit(depositAmount0, depositAmount1);

        // check return values
        assertEqDecimal(shares, newLiquidity, DECIMALS);
        assertEqDecimal(amount0, depositAmount0, DECIMALS);
        assertEqDecimal(amount1, depositAmount1, DECIMALS);

        // check token balances
        assertEqDecimal(token0.balanceOf(address(this)), 0, DECIMALS);
        assertEqDecimal(token1.balanceOf(address(this)), 0, DECIMALS);
        assertEqDecimal(bunni.balanceOf(address(this)), shares, DECIMALS);
    }

    function test_withdraw() public {
        // make deposit
        uint256 depositAmount0 = PRECISION;
        uint256 depositAmount1 = PRECISION;
        (uint256 shares, , , ) = _makeDeposit(depositAmount0, depositAmount1);

        // withdraw
        IBunni.WithdrawParams memory withdrawParams = IBunni.WithdrawParams({
            recipient: address(this),
            shares: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        (, uint256 withdrawAmount0, uint256 withdrawAmount1) = bunni.withdraw(
            withdrawParams
        );

        // check return values
        // withdraw amount less than original due to rounding
        assertEqDecimal(withdrawAmount0, depositAmount0 - 1, DECIMALS);
        assertEqDecimal(withdrawAmount1, depositAmount1 - 1, DECIMALS);

        // check token balances
        assertEqDecimal(
            token0.balanceOf(address(this)),
            depositAmount0 - 1,
            DECIMALS
        );
        assertEqDecimal(
            token1.balanceOf(address(this)),
            depositAmount1 - 1,
            DECIMALS
        );
        assertEqDecimal(bunni.balanceOf(address(this)), 0, DECIMALS);
    }

    function test_compound() public {
        // make deposit
        uint256 depositAmount0 = PRECISION;
        uint256 depositAmount1 = PRECISION;
        _makeDeposit(depositAmount0, depositAmount1);

        // do a few trades to generate fees
        {
            // swap token0 to token1
            uint256 amountIn = PRECISION / 100;
            token0.mint(address(this), amountIn);
            ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter
                .ExactInputSingleParams({
                    tokenIn: address(token0),
                    tokenOut: address(token1),
                    fee: fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });
            router.exactInputSingle(swapParams);
        }

        {
            // swap token1 to token0
            uint256 amountIn = PRECISION / 50;
            token1.mint(address(this), amountIn);
            ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter
                .ExactInputSingleParams({
                    tokenIn: address(token1),
                    tokenOut: address(token0),
                    fee: fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });
            router.exactInputSingle(swapParams);
        }

        // compound
        (uint256 addedLiquidity, uint256 amount0, uint256 amount1) = bunni
            .compound();

        // check added liquidity
        assertGtDecimal(addedLiquidity, 0, DECIMALS);
        assertGtDecimal(amount0, 0, DECIMALS);
        assertGtDecimal(amount1, 0, DECIMALS);

        // check token balances
        assertLtDecimal(token0.balanceOf(address(bunni)), EPSILON, DECIMALS);
        assertLtDecimal(token1.balanceOf(address(bunni)), EPSILON, DECIMALS);
    }

    function test_pricePerFullShare() public {
        // make deposit
        uint256 depositAmount0 = PRECISION;
        uint256 depositAmount1 = PRECISION;
        (
            uint256 shares,
            uint128 newLiquidity,
            uint256 newAmount0,
            uint256 newAmount1
        ) = _makeDeposit(depositAmount0, depositAmount1);

        (uint128 liquidity, uint256 amount0, uint256 amount1) = bunni
            .pricePerFullShare();

        assertEqDecimal(
            liquidity,
            (newLiquidity * PRECISION) / shares,
            DECIMALS
        );
        assertEqDecimal(amount0, (newAmount0 * PRECISION) / shares, DECIMALS);
        assertEqDecimal(amount1, (newAmount1 * PRECISION) / shares, DECIMALS);
    }

    function _makeDeposit(uint256 depositAmount0, uint256 depositAmount1)
        internal
        returns (
            uint256 shares,
            uint128 newLiquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        // mint tokens
        token0.mint(address(this), depositAmount0);
        token1.mint(address(this), depositAmount1);

        // deposit tokens
        // max slippage is 1%
        IBunni.DepositParams memory depositParams = IBunni.DepositParams({
            amount0Desired: depositAmount0,
            amount1Desired: depositAmount1,
            amount0Min: (depositAmount0 * 99) / 100,
            amount1Min: (depositAmount1 * 99) / 100,
            deadline: block.timestamp,
            recipient: address(this)
        });
        return bunni.deposit(depositParams);
    }
}
