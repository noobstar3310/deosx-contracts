# Short commands for the Sepolia rehearsal. Run from the repo root.
# Inputs come from .env (git-ignored): SAFE_ADDRESS, ETHERSCAN_API_KEY, SEPOLIA_RPC_URL.
# Deploys sign with the Foundry keystore below; forge asks for its password. Nothing here touches mainnet.

-include .env
export

ACCOUNT := TEIZA-dev-wallet
SEPOLIA_RPC := $(SEPOLIA_RPC_URL)
VERIFY   = --verify   # forge reads ETHERSCAN_API_KEY from the environment, so the key is never printed

TETHER_RUN = broadcast/DeployTestTether.s.sol/11155111/run-latest.json
VAULT_RUN  = broadcast/Deploy.s.sol/11155111/run-latest.json
FAUCET_RUN = broadcast/DeploySepoliaFaucet.s.sol/11155111/run-latest.json

# Addresses read from the last broadcast; override on the command line (make check VAULT=0x..).
TETHER := $(shell jq -r '.transactions[] | select(.transactionType=="CREATE") | .contractAddress' $(TETHER_RUN) 2>/dev/null | head -1)
VAULT  := $(shell jq -r '.transactions[] | select(.contractName=="DeosxVault" and .transactionType=="CREATE") | .contractAddress' $(VAULT_RUN) 2>/dev/null | head -1)
FAUCET := $(shell jq -r '.transactions[] | select(.contractName=="SepoliaFaucet" and .transactionType=="CREATE") | .contractAddress' $(FAUCET_RUN) 2>/dev/null | head -1)

.PHONY: help test fork dry-tether deploy-tether dry-vault deploy-vault addresses check mint operator-check dry-faucet deploy-faucet fund-faucet faucet-check

help:
	@echo "make test            run all tests"
	@echo "make fork            run the fork tests against live Sepolia and mainnet"
	@echo "make dry-tether      simulate the TestTether deploy (sends nothing)"
	@echo "make deploy-tether   deploy and verify TestTether"
	@echo "make dry-vault       simulate the vault deploy (sends nothing)"
	@echo "make deploy-vault    deploy and verify the vault, owned by SAFE_ADDRESS"
	@echo "make addresses       print the deployed addresses"
	@echo "make check           read the vault's settings on-chain"
	@echo "make mint TO=0x.. AMOUNT=100000   mint test USDT (whole USDT)"
	@echo "make operator-check OP=0x..       is OP an operator?"
	@echo "make dry-faucet RELAYER=0x..      simulate the ETH faucet deploy (sends nothing)"
	@echo "make deploy-faucet RELAYER=0x..   deploy and verify the ETH faucet, dripped by RELAYER"
	@echo "make fund-faucet AMOUNT=0.5       send AMOUNT Sepolia ETH to the faucet"
	@echo "make faucet-check                 read the faucet's settings and balances"

test:
	forge test

fork:
	SEPOLIA_RPC_URL=$(SEPOLIA_RPC) MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com \
	  forge test --match-contract "Sepolia|Mainnet"

dry-tether:
	forge script script/DeployTestTether.s.sol:DeployTestTether --rpc-url $(SEPOLIA_RPC)

deploy-tether:
	forge script script/DeployTestTether.s.sol:DeployTestTether --rpc-url $(SEPOLIA_RPC) \
	  --account $(ACCOUNT) --broadcast $(VERIFY)
	@echo "TestTether: $$(jq -r '.transactions[0].contractAddress' $(TETHER_RUN))"

dry-vault: need-tether
	USDT_ADDRESS=$(TETHER) forge script script/Deploy.s.sol:Deploy --rpc-url $(SEPOLIA_RPC)

deploy-vault: need-tether
	USDT_ADDRESS=$(TETHER) forge script script/Deploy.s.sol:Deploy --rpc-url $(SEPOLIA_RPC) \
	  --account $(ACCOUNT) --broadcast $(VERIFY)

addresses:
	@echo "TestTether: $(TETHER)"
	@echo "Vault:      $(VAULT)"
	@for i in 0 1 2; do \
	  echo "LP $$i:       $$(cast call $(VAULT) 'trancheInfo(uint256)((uint256,uint256,uint256,uint256,uint256,address))' $$i --rpc-url $(SEPOLIA_RPC) | tr -d '()' | awk -F', ' '{print $$6}')"; \
	done

check: need-vault
	@echo "owner          $$(cast call $(VAULT) 'owner()(address)' --rpc-url $(SEPOLIA_RPC))"
	@echo "usdt           $$(cast call $(VAULT) 'usdt()(address)' --rpc-url $(SEPOLIA_RPC))"
	@echo "halfTierAfter  $$(cast call $(VAULT) 'halfTierAfter()(uint64)' --rpc-url $(SEPOLIA_RPC))"
	@echo "fullTierAfter  $$(cast call $(VAULT) 'fullTierAfter()(uint64)' --rpc-url $(SEPOLIA_RPC))"
	@echo "openingMin     $$(cast call $(VAULT) 'openingMinimum()(uint256)' --rpc-url $(SEPOLIA_RPC))"
	@echo "topUpMin       $$(cast call $(VAULT) 'topUpMinimum()(uint256)' --rpc-url $(SEPOLIA_RPC))"

mint: need-tether
	@test -n "$(TO)" -a -n "$(AMOUNT)" || (echo "usage: make mint TO=0x.. AMOUNT=100000" && exit 1)
	cast send $(TETHER) 'mint(address,uint256)' $(TO) $(AMOUNT)000000 --rpc-url $(SEPOLIA_RPC) --account $(ACCOUNT)

operator-check: need-vault
	@test -n "$(OP)" || (echo "usage: make operator-check OP=0x.." && exit 1)
	@cast call $(VAULT) 'isOperator(address)(bool)' $(OP) --rpc-url $(SEPOLIA_RPC)

dry-faucet: need-relayer
	RELAYER_ADDRESS=$(RELAYER) forge script script/DeploySepoliaFaucet.s.sol:DeploySepoliaFaucet --rpc-url $(SEPOLIA_RPC)

deploy-faucet: need-relayer
	RELAYER_ADDRESS=$(RELAYER) forge script script/DeploySepoliaFaucet.s.sol:DeploySepoliaFaucet --rpc-url $(SEPOLIA_RPC) \
	  --account $(ACCOUNT) --broadcast $(VERIFY)
	@echo "SepoliaFaucet: $$(jq -r '.transactions[0].contractAddress' $(FAUCET_RUN))"

fund-faucet: need-faucet
	@test -n "$(AMOUNT)" || (echo "usage: make fund-faucet AMOUNT=0.5   (Sepolia ETH)" && exit 1)
	cast send $(FAUCET) --value $(AMOUNT)ether --rpc-url $(SEPOLIA_RPC) --account $(ACCOUNT)

faucet-check: need-faucet
	@echo "faucet         $(FAUCET)"
	@echo "owner          $$(cast call $(FAUCET) 'owner()(address)' --rpc-url $(SEPOLIA_RPC))"
	@echo "relayer        $$(cast call $(FAUCET) 'relayer()(address)' --rpc-url $(SEPOLIA_RPC))"
	@echo "dripAmount     $$(cast call $(FAUCET) 'dripAmount()(uint256)' --rpc-url $(SEPOLIA_RPC)) wei"
	@echo "cooldown       $$(cast call $(FAUCET) 'cooldown()(uint256)' --rpc-url $(SEPOLIA_RPC)) s"
	@echo "faucet ETH     $$(cast balance $(FAUCET) --ether --rpc-url $(SEPOLIA_RPC))"
	@echo "relayer ETH    $$(cast balance $$(cast call $(FAUCET) 'relayer()(address)' --rpc-url $(SEPOLIA_RPC)) --ether --rpc-url $(SEPOLIA_RPC))"

need-relayer:
	@test -n "$(RELAYER)" || (echo "usage: make deploy-faucet RELAYER=0x..  (the portals' FAUCET_RELAYER_ADDRESS)" && exit 1)

need-faucet:
	@test -n "$(FAUCET)" || (echo "No faucet yet: run make deploy-faucet first (or pass FAUCET=0x..)" && exit 1)

need-tether:
	@test -n "$(TETHER)" || (echo "No TestTether yet: run make deploy-tether first (or pass TETHER=0x..)" && exit 1)

need-vault:
	@test -n "$(VAULT)" || (echo "No vault yet: run make deploy-vault first (or pass VAULT=0x..)" && exit 1)
