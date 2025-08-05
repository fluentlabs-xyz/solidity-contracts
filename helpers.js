module.exports = {
    FLUENT_HOST: `127.0.0.1`,
    FLUENT_NODE_PORT: 8545,
    EVM_HOST: `127.0.0.1`,
    EVM_NODE_PORT: 8546,
    fluent_provider_url,
    evm_provider_url,
}

function fluent_provider_url() {
    return `http://${module.exports.FLUENT_HOST}:${module.exports.FLUENT_NODE_PORT}`
    // return `https://rpc.dev1.fluentlabs.xyz/`
}

function evm_provider_url() {
    return `http://${module.exports.EVM_HOST}:${module.exports.EVM_NODE_PORT}`
}