import { parseEther } from 'ethers/lib/utils'
const MAX_UINT = parseEther('10000000000000000000000000000000000000')

const batchApproval = async (arrayOfAddresses, arrayOfTokens, arrayOfSigners) => {
  // for each contract
  for (let c = 0; c < arrayOfAddresses.length; c++) {
    let address = arrayOfAddresses[c]
    // for each token
    for (let t = 0; t < arrayOfTokens.length; t++) {
      let token = arrayOfTokens[t]
      // for each owner
      for (let u = 0; u < arrayOfSigners.length; u++) {
        let signer = arrayOfSigners[u]
        let allowance = await token.allowance(signer.address, address)
        if (allowance < MAX_UINT) {
          await token.connect(signer).approve(address, MAX_UINT)
        }
      }
    }
  }
}

export default batchApproval
