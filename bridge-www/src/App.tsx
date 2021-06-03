import React, { useEffect, useMemo, useState } from 'react';
import { MetaMaskInpageProvider } from "@metamask/providers";
import { WrappedNcgBalance } from "./components/WrappedNcgBalance";
import { isAddress } from 'web3-utils';
import Web3 from 'web3';
import { provider as Provider } from 'web3-core';
import { Contract } from "web3-eth-contract";
import { wNCGAbi } from "./wrapped-ncg-token";

declare global {
  interface Window {
    ethereum: MetaMaskInpageProvider | undefined;
  }
}

function App() {
  const [web3, setWeb3] = useState<Web3 | null>(null);
  const [account, setAccount] = useState<string | null>(null);
  const [accounts, setAccounts] = useState<string[] | null>(null);
  const [contractAddress, setContractAddress] = useState<string>("0x2395900038eEf1814161A76621912B3599D7d242");
  const [ncAddress, setNcAddress] = useState<string>("");
  const [amount, setAmount] = useState<string>("0");
  const validContractAddress = useMemo<boolean>(() => isAddress(contractAddress), [contractAddress]);
  const contract = useMemo<Contract | null>(() => web3 !== null && validContractAddress
    ? new web3.eth.Contract(wNCGAbi, contractAddress)
    : null,
    [web3, validContractAddress, contractAddress]);

  useEffect(() => {
    if (window.ethereum === undefined || !window.ethereum.isMetaMask) {
      return;
    } else {
      // FIXME: ethereum.enable() method was deprecated. Use ethereum.request(...) method.
      window.ethereum.enable();
      setWeb3(new Web3(window.ethereum as Provider))
    }
  }, []);

  useEffect(() => {
    if (web3 === null) {
      return;
    }

    web3.eth.requestAccounts().then(accounts => {
      setAccounts(accounts);
      setAccount(accounts[0]);
    });
  }, [web3]);


  if (web3 === null) {
    return <h1>Maybe MetaMask doesn't exist. 😥</h1>;
  }

  console.log(contract, contractAddress, accounts, account, amount)
  return (
    <div className="App">
      Contract Address : <input type="text" value={contractAddress} onChange={event => setContractAddress(event.target.value)} />
      <br />
      Choose Address : {
        accounts === null
          ? <b>🕑</b>
          : <select onChange={event => setAccount(event.target.value)}>{accounts.map(account => <option>{account}</option>)}</select>
      }
      <br />
      Your wNCG :
      {
        contract === null || account === null
          ? <b>🕑</b>
          : <WrappedNcgBalance address={account} balanceOf={(address: string) => contract.methods.balanceOf(address).call()} />
      }
      <hr/>
      Amount : <input type="text" value={amount} onChange={event => { setAmount(event.target.value) }}/>
      <br/>
      To : <input type="text" value={ncAddress} onChange={event => { setNcAddress(event.target.value) }}/>
      <br/>
      {
        contract === null || account === null || amount === null || isNaN(parseInt(amount)) || !isAddress(ncAddress)
          ? <b>Fill corret values</b>
          : <button onClick={event => {
            event.preventDefault();            
            contract.methods.burn(amount, ncAddress).send({ from: account }).then(console.debug)
          }}>Burn</button>
      }
    </div>
  );
}

export default App;
