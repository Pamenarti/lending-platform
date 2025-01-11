const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Lending Pool", function () {
    let LendingPool, pool;
    let TestToken, token1, token2;
    let PriceOracle, oracle;
    let InterestRateModel, interestModel;
    let owner, user1, user2;
    
    const INITIAL_SUPPLY = ethers.utils.parseEther("1000000");
    const SUPPLY_AMOUNT = ethers.utils.parseEther("1000");
    const BORROW_AMOUNT = ethers.utils.parseEther("500");
    const LIQUIDATION_INCENTIVE = ethers.utils.parseEther("1.1"); // 10% bonus
    
    beforeEach(async function () {
        [owner, user1, user2] = await ethers.getSigners();
        
        // Deploy test tokens
        TestToken = await ethers.getContractFactory("TestToken");
        token1 = await TestToken.deploy("Token1", "TK1");
        token2 = await TestToken.deploy("Token2", "TK2");
        await Promise.all([token1.deployed(), token2.deployed()]);
        
        // Deploy price oracle
        PriceOracle = await ethers.getContractFactory("PriceOracle");
        oracle = await PriceOracle.deploy();
        await oracle.deployed();
        
        // Set token prices
        await oracle.updatePrice(token1.address, ethers.utils.parseEther("1"));
        await oracle.updatePrice(token2.address, ethers.utils.parseEther("1"));
        
        // Deploy interest rate model
        InterestRateModel = await ethers.getContractFactory("InterestRateModel");
        interestModel = await InterestRateModel.deploy();
        await interestModel.deployed();
        
        // Deploy lending pool
        LendingPool = await ethers.getContractFactory("LendingPool");
        pool = await LendingPool.deploy(oracle.address, LIQUIDATION_INCENTIVE);
        await pool.deployed();
        
        // List markets
        await pool.listMarket(
            token1.address,
            interestModel.address,
            ethers.utils.parseEther("0.1"), // 10% reserve factor
            ethers.utils.parseEther("0.8")  // 80% collateral factor
        );
        
        await pool.listMarket(
            token2.address,
            interestModel.address,
            ethers.utils.parseEther("0.1"),
            ethers.utils.parseEther("0.8")
        );
        
        // Mint tokens to users
        await token1.mint(user1.address, INITIAL_SUPPLY);
        await token2.mint(user1.address, INITIAL_SUPPLY);
        await token1.mint(user2.address, INITIAL_SUPPLY);
        await token2.mint(user2.address, INITIAL_SUPPLY);
    });
    
    describe("Supply", function () {
        it("Should supply tokens correctly", async function () {
            await token1.connect(user1).approve(pool.address, SUPPLY_AMOUNT);
            
            await expect(
                pool.connect(user1).supply(token1.address, SUPPLY_AMOUNT)
            ).to.emit(pool, "Supplied")
             .withArgs(token1.address, user1.address, SUPPLY_AMOUNT);
            
            const userData = await pool.userData(token1.address, user1.address);
            expect(userData.supplied).to.equal(SUPPLY_AMOUNT);
        });
    });
    
    describe("Borrow", function () {
        beforeEach(async function () {
            await token1.connect(user1).approve(pool.address, SUPPLY_AMOUNT);
            await pool.connect(user1).supply(token1.address, SUPPLY_AMOUNT);
        });
        
        it("Should borrow tokens correctly", async function () {
            await expect(
                pool.connect(user1).borrow(token2.address, BORROW_AMOUNT)
            ).to.emit(pool, "Borrowed")
             .withArgs(token2.address, user1.address, BORROW_AMOUNT);
            
            const userData = await pool.userData(token2.address, user1.address);
            expect(userData.borrowed).to.equal(BORROW_AMOUNT);
        });
        
        it("Should fail if insufficient collateral", async function () {
            const largeBorrow = SUPPLY_AMOUNT.mul(2);
            
            await expect(
                pool.connect(user1).borrow(token2.address, largeBorrow)
            ).to.be.revertedWith("Insufficient collateral");
        });
    });
    
    describe("Liquidation", function () {
        beforeEach(async function () {
            // User1 supplies token1 and borrows token2
            await token1.connect(user1).approve(pool.address, SUPPLY_AMOUNT);
            await pool.connect(user1).supply(token1.address, SUPPLY_AMOUNT);
            await pool.connect(user1).borrow(token2.address, BORROW_AMOUNT);
            
            // Drop token1 price to make user1's position liquidatable
            await oracle.updatePrice(
                token1.address,
                ethers.utils.parseEther("0.5")
            );
        });
        
        it("Should liquidate position correctly", async function () {
            await token2.connect(user2).approve(pool.address, BORROW_AMOUNT);
            
            await expect(
                pool.connect(user2).liquidate(
                    user1.address,
                    token2.address,
                    token1.address,
                    BORROW_AMOUNT
                )
            ).to.emit(pool, "Liquidated");
            
            const userData = await pool.userData(token2.address, user1.address);
            expect(userData.borrowed).to.equal(0);
        });
    });
}); 