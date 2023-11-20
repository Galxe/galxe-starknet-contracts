# Galxe Starknet NFT

## Contracts (Mainnet):
Class Hash: 0x39a03711fd9d5b7cffb4a1dbbe08cd9288fd3785ca428f8154785a2933db774

Dep:
* cairo v0.12.0
* starknet v0.12.0
* [Scarb v2.3.1](https://docs.swmansion.com/scarb/docs)
* [Starknet Foundry v0.10.2](https://foundry-rs.github.io/starknet-foundry/getting-started/installation.html)

```
# build-testnet
> scarb build

# create deployer account
> starkli account oz init ~/.starkli-wallets/deployer/account
> starkli account deploy ~/.starkli-wallets/deployer/account


# declare-testnet
> sncast declare --contract-name StarNFT

# deploy-testnet
> starkli deploy $CLASS_HASH $NAME $SYMBOL $BASE_URI $SIGNER_PUB_KEY
```