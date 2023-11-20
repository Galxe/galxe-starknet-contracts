CLASS_HASH=0x39c3dbca0bfb783ee65782dc21e4a0f41c8cd9875cddea0d7445ed2e31f72e8

clean:
	rm -rf target

build: clean
	scarb build


declare-mainnet:
	sncast --profile prd declare --contract-name StarNFT

deploy-mainnet:
	sncast --profile prd deploy --class-hash $(CLASS_HASH) --constructor-calldata "0x47616c7865204e4654 0x4f4154 0x707264 0x07aa609f16de050ab3a638f7a776e41b8aac38ca2ee985925f3a638d36be1f68 0x077E04dEb40385077d759C1aB74A3E6aC11DCF5BD6399b442E11109e2a2ba800"

.PHONY: build declare-mainnet deploy-mainnet