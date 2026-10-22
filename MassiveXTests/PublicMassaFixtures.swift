// PUBLIC, known-insecure test vectors from @massalabs/massa-web3 5.4.0. NEVER FUND.
import Foundation

enum PublicMassaFixtures {
    static let json = #"""
{
  "warning": "PUBLIC TEST VECTORS. Known insecure keys. NEVER FUND on any network.",
  "sdkVersion": "5.4.0",
  "sdkRevision": "d48c0db559ff35e84b38c481a447345b540e22b7",
  "vectors": [
    {
      "pattern": "zero",
      "seedHex": "0000000000000000000000000000000000000000000000000000000000000000",
      "privateKey": "S1111111111111111111111111111111112m1s9K",
      "publicKey": "P1TAfk4W8xsRPnfJGZwRznpZq8MxzdCEGv65UFx3RnNbft1hwLg",
      "publicKeyHex": "3b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da29",
      "address": "AU1rqxSMewKgJU2m5orM2HFuMg7ioEFiECuhX1sSken92VxUBfQy",
      "addressHashHex": "712d5312e42a9edb3b1c734b300aa3d783c2c4592bd880385098e11876aa29b4",
      "messageHex": "4d617373697665205820302e33205055424c49432054455354204f4e4c59207a65726f",
      "signature": "1BcXUNF8Zu7MNDaTqjC1xZZPpPbh7GX3nt1un1c5FNYU8D6NCwVZUUdAugbfTFhnDj8WTPNmdq5iPaUfcQiHb3Xku2korV",
      "signatureHex": "511e227981cc3024093d66426ff81943501bdf124503a0cd5fa5b3842b3b8f1a511badf47974484177d4af563801b2d0d188f7030a6b784d9854734c7c889801"
    },
    {
      "pattern": "ascending",
      "seedHex": "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
      "privateKey": "S116qJFWMMHFy3xDdLmvUeyc2S6FrWRhJP51HsvDYdz9fTk5aq",
      "publicKey": "P12bhWxVMnpe1aKnpUNzPSP2kGFCEioBa72QszMhQcqLkRigynP",
      "publicKeyHex": "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8",
      "address": "AU12MBEEKVAFZhxYzeyNYpAAcKEu667KKjHBos9i65htLwPkHyQG4",
      "addressHashHex": "b1824b170cc25c8d8dbc6ac5e89e5ec7ec9063db8ea89bb3232c720594373f58",
      "messageHex": "4d617373697665205820302e33205055424c49432054455354204f4e4c5920617363656e64696e67",
      "signature": "1ZJUt7SDC7e5f3duE2KNR2SNsBrHnmiLofuH4iVE1rEBBYnCgS1VLYk1EZxDsnAd3ApqCKddxFVtose6kQKdfHkQqkpEQz",
      "signatureHex": "f6e61734553b5ab7d500fbe50832de15e0ad32ba7ad775601560ec03e7e2f98d6324b89e19d0de1d533590deb6c5a6f535ff7d21a4618d1d7fab9ce34eff5f02"
    },
    {
      "pattern": "descending",
      "seedHex": "fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0",
      "privateKey": "S12wk5Q9nM5KwsrXkgxHE2qwoK6BdPrLT6Lh3Eroyn7NQLy2EZDM",
      "publicKey": "P12RMJwGBfGkZHzp4wZkKFKJXeFwAhNL5czgFiWM6HdGyNGNygJw",
      "publicKeyHex": "bafc71bead3ac5e4b63e9c8216ee71a34aaec65722eedbca728b4e9b3ccce396",
      "address": "AU12b9KwUq6tSJ1hG2EdLrysd9LWEhshwNp514hAJ2RskT4kc7voi",
      "addressHashHex": "d13925705a91e6c9f0b5edf79f1af7c8fae7046c3af9df96651dde4d061109b6",
      "messageHex": "4d617373697665205820302e33205055424c49432054455354204f4e4c592064657363656e64696e67",
      "signature": "1WX65HpJ86MCyu8f4b7Rg5xCJJ5SRc5shwMPJ4qZGadBV38TQUFUnJTbMV6xXbVP53JKKc1KGRvCWiDDKX2iXxUvqS8aDf",
      "signatureHex": "e1a1206b3a7a7a796a2c34e1b0f843aa68d7e08cd28fddbfe31412dbf4d06157cf5d4ad1a3d34b0aa5d573664c787cfa44b2abd00c71d7be7f1a85bcddd64608"
    },
    {
      "pattern": "ones",
      "seedHex": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "privateKey": "S12wkBET2rRgE8pahuaczxKbmv7ciehqsne57F9gtzf1PVawbBMp",
      "publicKey": "P1uFFZ8m3RfRw7LwA7Q58XdSLtdBcyPZMjnMLPK196PCvoTeuWa",
      "publicKeyHex": "76a1592044a6e4f511265bca73a604d90b0529d1df602be30a19a9257660d1f5",
      "address": "AU1FgfkVQ5nVCHdw9n4Rt6Lq9EULgicGPTWLNzM5NxD6g8TrJVyi",
      "addressHashHex": "21577766cab7a7a9e926b8dbd42eec543c0434724142ed098089f24666143066",
      "messageHex": "4d617373697665205820302e33205055424c49432054455354204f4e4c59206f6e6573",
      "signature": "1Vc1CAoa6UdAFzbf4U2RWfHypS1pCMCsXPHwbMRrrXttstibG2wMwgsyxPK7jT6rVCDxQEVp4pZd8zpFZmmnefzhoqZVry",
      "signatureHex": "daa236801b317cdda3cb5ed64348de8aa5cf624290011a062cfb3212cb4a4f7821135ee4b4f17abc111d2e7e9aee988a02f889b1e8f937a708a685a2d3b6d70a"
    }
  ],
  "malformed": [
    {
      "name": "unsupported-version",
      "value": "S2wkBET2rRgE8pahuaczxKbmv7ciehqsne57F9gtzf1PVdr2VP3"
    },
    {
      "name": "short-payload",
      "value": "S11111111111111111111111111111111273Yts"
    },
    {
      "name": "long-payload",
      "value": "S1111111111111111111111111111111111fupDZ"
    },
    {
      "name": "noncanonical-varint",
      "value": "SKwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73NUBByJr"
    }
  ]
}
"""#
}
