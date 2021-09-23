const SombraMarketplace = artifacts.require("SombraMarketplace");

module.exports = function (deployer) {
  deployer.deploy(SombraMarketplace, '0x749B973d092eFfcb46f0C5f141E5aD6F6E448F37', '0x10ED43C718714eb63d5aA57B78B54704E256024E');
};
