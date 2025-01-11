const ethers = require('ethers');
const Web3 = require('web3');
const dotenv = require('dotenv');
const lendingPoolABI = require('./artifacts/contracts/LendingPool.sol/LendingPool.json').abi;

class LendingService {
    constructor() {
        dotenv.config();
        this.provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
        this.wallet = new ethers.Wallet(process.env.PRIVATE_KEY, this.provider);
        this.contractAddress = process.env.LENDING_POOL_ADDRESS;
    }

    async initializeContract() {
        this.contract = new ethers.Contract(
            this.contractAddress,
            lendingPoolABI,
            this.provider
        );
        this.contractWithSigner = this.contract.connect(this.wallet);
    }

    async supply(tokenAddress, amount) {
        const token = new ethers.Contract(
            tokenAddress,
            ['function approve(address spender, uint256 amount) external returns (bool)'],
            this.wallet
        );

        await token.approve(this.contractAddress, amount);
        const tx = await this.contractWithSigner.supply(tokenAddress, amount);
        return await tx.wait();
    }

    async borrow(tokenAddress, amount) {
        const tx = await this.contractWithSigner.borrow(tokenAddress, amount);
        return await tx.wait();
    }

    async repay(tokenAddress, amount) {
        const token = new ethers.Contract(
            tokenAddress,
            ['function approve(address spender, uint256 amount) external returns (bool)'],
            this.wallet
        );

        await token.approve(this.contractAddress, amount);
        const tx = await this.contractWithSigner.repay(tokenAddress, amount);
        return await tx.wait();
    }

    async withdraw(tokenAddress, amount) {
        const tx = await this.contractWithSigner.withdraw(tokenAddress, amount);
        return await tx.wait();
    }

    async liquidate(borrower, tokenBorrowed, tokenCollateral, amount) {
        const token = new ethers.Contract(
            tokenBorrowed,
            ['function approve(address spender, uint256 amount) external returns (bool)'],
            this.wallet
        );

        await token.approve(this.contractAddress, amount);
        const tx = await this.contractWithSigner.liquidate(
            borrower,
            tokenBorrowed,
            tokenCollateral,
            amount
        );
        return await tx.wait();
    }

    async getAccountLiquidity(address) {
        const liquidity = await this.contract.getAccountLiquidity(address);
        return ethers.utils.formatEther(liquidity);
    }

    async getAccountHealth(address) {
        const health = await this.contract.getAccountHealth(address);
        return ethers.utils.formatEther(health);
    }

    async getMarketData(tokenAddress) {
        const market = await this.contract.markets(tokenAddress);
        return {
            totalSupply: ethers.utils.formatEther(market.totalSupply),
            totalBorrows: ethers.utils.formatEther(market.totalBorrows),
            reserveFactor: ethers.utils.formatEther(market.reserveFactor),
            collateralFactor: ethers.utils.formatEther(market.collateralFactor),
            isListed: market.isListed
        };
    }

    async getUserData(tokenAddress, userAddress) {
        const data = await this.contract.userData(tokenAddress, userAddress);
        return {
            borrowed: ethers.utils.formatEther(data.borrowed),
            supplied: ethers.utils.formatEther(data.supplied),
            lastUpdateTimestamp: new Date(data.lastUpdateTimestamp.toNumber() * 1000)
        };
    }

    async listenToEvents() {
        this.contract.on("Supplied", (token, user, amount, event) => {
            console.log(`
                Supply:
                Token: ${token}
                User: ${user}
                Amount: ${ethers.utils.formatEther(amount)}
            `);
        });

        this.contract.on("Borrowed", (token, user, amount, event) => {
            console.log(`
                Borrow:
                Token: ${token}
                User: ${user}
                Amount: ${ethers.utils.formatEther(amount)}
            `);
        });

        this.contract.on("Liquidated", 
            (liquidator, borrower, tokenBorrowed, tokenCollateral, amount, event) => {
                console.log(`
                    Liquidation:
                    Liquidator: ${liquidator}
                    Borrower: ${borrower}
                    Token Borrowed: ${tokenBorrowed}
                    Token Collateral: ${tokenCollateral}
                    Amount: ${ethers.utils.formatEther(amount)}
                `);
            }
        );
    }
}

module.exports = LendingService; 