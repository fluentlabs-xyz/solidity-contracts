.PHONY: prepare
prepare:
	yarn install
	yarn build

EVM_NODE_HOST:=127.0.0.1
EVM_NODE_PORT:=8546
.PHONY: run_evm_node
run_evm_node:
	npx hardhat node --port $(EVM_NODE_PORT) --hostname $(EVM_NODE_HOST)

FLUENT_NODE_PORT:=8545
.PHONY: run_evm_node2
run_evm_node2:
	$(MAKE) run_evm_node EVM_NODE_PORT=$(FLUENT_NODE_PORT)

NETWORK_NAME:=L1
.PHONY: _run_test
_run_test:
	npx hardhat test test/e2e/$(TEST_NAME).js --network $(NETWORK_NAME) || true
	notify-send "bridge-contracts" "_run_test '$(TEST_NAME)' finished" || true

.PHONY: test_TokenApprove
test_TokenApprove:
	$(MAKE) _run_test TEST_NAME=TokenApprove

.PHONY: test_SendTokens
test_SendTokens:
	$(MAKE) _run_test TEST_NAME=SendTokens

.PHONY: test_RestakeTokens
test_RestakeTokens:
	$(MAKE) _run_test TEST_NAME=RestakeTokens

.PHONY: format
format:
	yarn format