const SombraMarketplace = artifacts.require("SombraMarketplace");

module.exports = function (deployer) {
  deployer.deploy(SombraMarketplace, '0x749B973d092eFfcb46f0C5f141E5aD6F6E448F37');
};
