import { assert, expect } from 'chai'
import { Contract, BigNumber, Wallet } from 'ethers'
import { keccak256, defaultAbiCoder, toUtf8Bytes, solidityPack } from 'ethers/lib/utils'
import { ethers } from 'hardhat'
const { parseEther } = ethers.utils
const { AddressZero } = ethers.constants
import hardhat from 'hardhat'

/**
 * @dev If the allowance of an account is less than some large amount, approve a large amount.
 * @param {*} owner The signer account calling the transaction.
 * @param {*} spender The signer account that should be approved.
 * @param {*} token The ERC-20 token to update its allowance mapping.
 */
export const checkAllowance = async (owner, spender, token) => {
  const amount = parseEther('10000000000')
  let allowance = await token.allowance(owner.address, spender.address)
  if (allowance <= amount) {
    await token.approve(spender.address, amount, { from: owner.address })
  }
}

/**
 * @dev Checks the Registry contract to make sure it has set its factory addresses.
 * @param {*} registry The Registry contract instance.
 * @param {*} optionFactory The OptionFactory contract instance.
 * @param {*} redeemFactory The RedeemFactory contract instance.
 */
export const checkInitialization = async (registry, optionFactory, redeemFactory) => {
  const optionFactoryAddress = await registry.optionFactory()
  const redeemFactoryAddress = await registry.redeemFactory()
  if (optionFactoryAddress == AddressZero) {
    await registry.setOptionFactory(optionFactory.address)
  }
  if (redeemFactoryAddress == AddressZero) {
    await registry.setRedeemFactory(redeemFactory.address)
  }
}

export const assertBNEqual = (actualBN, expectedBN, message?) => {
  assert.equal(actualBN.toString(), expectedBN.toString(), message)
}

export const assertWithinError = (actualBN, expectedBN, message?) => {
  let error = 1
  if (expectedBN !== 0) {
    let max = expectedBN.add(expectedBN.div(error))
    let min = expectedBN.sub(expectedBN.div(error))
    if (actualBN.gt(0)) {
      expect(actualBN).to.be.at.most(max)
      expect(actualBN).to.be.at.least(min)
    } else {
      expect(actualBN).to.be.at.most(0)
    }
  } else {
    expect(actualBN).to.be.eq(0)
  }
}

/**
 * @dev A generalized function to get the token balance of an address.
 * @param {*} token The ERC-20 token contract instance.
 * @param {*} address The address of the account to check the balance of.
 */
export const getTokenBalance = async (token, address) => {
  let bal = await token.balanceOf(address)
  return bal
}

/**
 * @dev Asserts the actual balances of underlying and strike tokens matches the cache balances.
 *      Asserts the balances of option and redeem tokens is 0.
 * @param {*} underlyingToken The contract instance of the underlying token.
 * @param {*} strikeToken The contract instance of the strike token.
 * @param {*} optionToken The contract instance of the option token.
 * @param {*} redeem The contract instance of the redeem token.
 */
export const verifyOptionInvariants = async (underlyingToken, strikeToken, optionToken, redeem) => {
  let underlyingBalance = await underlyingToken.balanceOf(optionToken.address)
  let underlyingCache = await optionToken.underlyingCache()
  let strikeCache = await optionToken.strikeCache()
  let strikeBalance = await strikeToken.balanceOf(optionToken.address)
  let optionBalance = await optionToken.balanceOf(optionToken.address)
  let redeemBalance = await redeem.balanceOf(optionToken.address)
  let optionTotalSupply = await optionToken.totalSupply()

  assertBNEqual(underlyingBalance, optionTotalSupply, `Under Bal != option supply`)
  assertBNEqual(underlyingCache, optionTotalSupply, `Under cache != option supply`)
  assertBNEqual(strikeBalance, strikeCache, `Strike Bal != strikeCache`)
  assertBNEqual(optionBalance, 0)
  assertBNEqual(redeemBalance, 0)
}

/**
 * @dev Gets the token balances for the four tokens, underlying, strike, option, and redeem.
 * @param {*} Primitive An object returned by the ../lib/setup function `newPrimitive()`
 * @param {*} address The address to check the balance of.
 */
export const getTokenBalances = async (Primitive, address) => {
  const underlyingBalance = await getTokenBalance(Primitive.underlyingToken, address)
  const strikeBalance = await getTokenBalance(Primitive.strikeToken, address)
  const redeemBalance = await getTokenBalance(Primitive.redeemToken, address)
  const optionBalance = await getTokenBalance(Primitive.optionToken, address)

  const tokenBalances = {
    underlyingBalance,
    strikeBalance,
    redeemBalance,
    optionBalance,
  }
  return tokenBalances
}

export const sortTokens = (tokenA, tokenB) => {
  let tokens = tokenA < tokenB ? [tokenA, tokenB] : [tokenB, tokenA]
  return tokens
}

export const getParams = (instance: Contract, method: string, args: any[]): any => {
  return instance.interface.encodeFunctionData(method, args)
}

export const balanceSnapshot = async function (wallet: Wallet, tokens: Contract[], account?: string): Promise<BigNumber[]> {
  let balances: BigNumber[] = []
  for (let i = 0; i < tokens.length; i++) {
    let token = tokens[i]
    let bal = BigNumber.from(await token.balanceOf(account ? account : wallet.address))
    balances.push(bal)
  }
  return balances
}

export const applyFunction = function (array1: any[], array2: any[], fn: any): any[] {
  let differences: any[] = []
  array1.map((item, i) => {
    let diff = fn(item, array2[i] /* `${item} against ${array2[i]} with index ${i}` */)
    differences.push(diff)
  })
  return differences
}

export const subtract = function (item1: BigNumber, item2: BigNumber, message?: string): BigNumber {
  if (message) console.log(message)
  return item1.sub(item2)
}

export const withinError = (a: BigNumber, b: BigNumber, percent?: number) => {
  percent = percent ? percent : 35
  a = a.abs()
  b = b.abs()
  assert.equal(
    a.gte(b.mul(100 - percent).div(100)) && a.lte(b.mul(100 + percent).div(100)),
    true,
    `${a.gte(b.mul(100 - percent).div(100))} &&  ${a.lte(b.mul(100 + percent).div(100))} is not true`
  )
}

const PERMIT_TYPEHASH = keccak256(
  toUtf8Bytes('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)')
)

const PERMIT_TYPEHASH_DAI = keccak256(
  toUtf8Bytes('Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)')
)

function getDomainSeparator(name: string, tokenAddress: string, chainId?: number) {
  return keccak256(
    defaultAbiCoder.encode(
      ['bytes32', 'bytes32', 'bytes32', 'uint256', 'address'],
      [
        keccak256(toUtf8Bytes('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
        keccak256(toUtf8Bytes(name)),
        keccak256(toUtf8Bytes('1')),
        chainId,
        tokenAddress,
      ]
    )
  )
}

export async function getApprovalDigest(
  token: Contract,
  approve: {
    owner: string
    spender: string
    value: BigNumber
  },
  nonce: BigNumber,
  deadline: BigNumber
): Promise<string> {
  const name = await token.name()
  const chainId: number = +(await hardhat.getChainId())
  const DOMAIN_SEPARATOR = await token.DOMAIN_SEPARATOR()
  return keccak256(
    solidityPack(
      ['bytes1', 'bytes1', 'bytes32', 'bytes32'],
      [
        '0x19',
        '0x01',
        DOMAIN_SEPARATOR,
        keccak256(
          defaultAbiCoder.encode(
            ['bytes32', 'address', 'address', 'uint256', 'uint256', 'uint256'],
            [PERMIT_TYPEHASH, approve.owner, approve.spender, approve.value, nonce, deadline]
          )
        ),
      ]
    )
  )
}

export async function getApprovalDigestDai(
  token: Contract,
  approve: {
    holder: string
    spender: string
    allowed: boolean
  },
  nonce: BigNumber,
  expiry: BigNumber
): Promise<string> {
  const name = await token.name()
  const chainId: number = +(await hardhat.getChainId())
  const DOMAIN_SEPARATOR = getDomainSeparator(name, token.address, chainId)
  return keccak256(
    solidityPack(
      ['bytes1', 'bytes1', 'bytes32', 'bytes32'],
      [
        '0x19',
        '0x01',
        DOMAIN_SEPARATOR,
        keccak256(
          defaultAbiCoder.encode(
            ['bytes32', 'address', 'address', 'uint256', 'uint256', 'bool'],
            [PERMIT_TYPEHASH_DAI, approve.holder, approve.spender, nonce, expiry, approve.allowed]
          )
        ),
      ]
    )
  )
}
