const fs = require("fs");
const path = require("path");

module.exports = {
    readBytecode(filepath) {
        const bytecode = fs.readFileSync(path.join(__dirname, filepath));
        const wasmBytecode = "0x" + bytecode.toString("hex");
        return wasmBytecode;
    }
}
